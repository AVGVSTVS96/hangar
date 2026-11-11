import { execFileSync } from "node:child_process";
import { createReadStream, watch } from "node:fs";
import { mkdir, readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";

import { z } from "zod";

import { appsDir, getApp, iconPath, ipaPath, listApps, phoneBuilds, setPhoneBuild } from "./store.ts";
import type { App } from "./store.ts";

const base = (process.env.HANGAR_URL ?? "").replace(/\/$/u, "");
const port = Number(process.env.HANGAR_PORT ?? "8792");

const escape = (text: string) => text.replaceAll(/[&<>"']/gu, (c) => `&#${c.codePointAt(0)};`);
const iconUrl = (app: App) => `${base}/apps/${app.id}/icon.png?${app.build}`;

const install = (app: App) =>
  `itms-services://?action=download-manifest&url=${encodeURIComponent(`${base}/apps/${app.id}/${app.build}/manifest.plist`)}`;

const manifest = (app: App) => {
  const asset = (kind: string, url: string) =>
    `<dict><key>kind</key><string>${kind}</string><key>url</key><string>${escape(url)}</string></dict>`;

  const assets = [
    asset("software-package", `${base}/apps/${app.id}/${app.build}.ipa`),
    ...(app.icon ? [asset("display-image", iconUrl(app))] : []),
  ];

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array>${assets.join("")}</array>
<key>metadata</key><dict>
<key>bundle-identifier</key><string>${escape(app.id)}</string>
<key>bundle-version</key><string>${app.build}</string>
<key>kind</key><string>software</string>
<key>title</key><string>${escape(app.name)}</string>
</dict></dict></array></dict></plist>
`;
};

const isHangar = (app: App) => app.id.endsWith(".hangar");

const page = (apps: App[]) => `<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>hangar</title>
<style>
body { font: 17px/1.4 -apple-system, system-ui; max-width: 30em; margin: 12vh auto 0; padding: 0 20px }
a { display: grid; grid-template-columns: 52px 1fr auto; gap: 14px; align-items: center; padding: 12px 0; color: inherit; text-decoration: none }
img, i { width: 52px; height: 52px; border-radius: 12px; background: #8884 }
b { font-weight: 600 } small { display: block; opacity: .6 }
span { padding: 6px 16px; border-radius: 99px; background: #0a84ff; color: white; font-weight: 600; font-size: 15px }
</style>
${apps
  .toSorted((a, b) => Number(isHangar(b)) - Number(isHangar(a)))
  .map(
    (
      app,
    ) => `<a href="${escape(install(app))}">${app.icon ? `<img src="${escape(iconUrl(app))}" alt="">` : "<i></i>"}
<div><b>${escape(app.name)}</b><small>${app.build}${app.notes === "" ? "" : ` · ${escape(app.notes)}`}</small></div><span>Install</span></a>`,
  )
  .join("\n")}
`;

const Whois = z.object({ Node: z.object({ ComputedName: z.string() }) });
const names = new Map<string, string>();

const device = (ip: string) => {
  let name = names.get(ip);

  if (name === undefined) {
    try {
      name = Whois.parse(
        JSON.parse(
          execFileSync("tailscale", ["whois", "--json", ip], {
            encoding: "utf-8",
            stdio: ["ignore", "pipe", "ignore"],
          }),
        ),
      ).Node.ComputedName;
    } catch {
      name = ip;
    }

    names.set(ip, name);
  }

  return name;
};

const log = (ip: string, line: string) => {
  console.log(`${device(ip)}: ${line}`);
};

const clientIp = (req: IncomingMessage) =>
  (req.headers["x-forwarded-for"]?.toString().split(",")[0] ?? req.socket.remoteAddress ?? "").trim();

interface Client {
  ip: string;
  res: ServerResponse;
}

const clients = new Set<Client>();

type Step = "asked" | "downloading" | "downloaded" | "stopped";

interface Install {
  id: string;
  build: number;
  step: Step;
  sent: number;
  size: number;
}

type PhoneApp = Awaited<ReturnType<typeof appsFor>>[number];

const send = (client: Client, event: "apps" | "install", data: PhoneApp[] | Install) => {
  client.res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
};

const appsFor = async (ip: string) => {
  const phone = await phoneBuilds(ip);

  return (await listApps()).map((app) => ({
    ...app,
    icon: app.icon ? iconUrl(app) : null,
    install: install(app),
    phone: phone[app.id] ?? null,
    scheme: `${app.id}-${app.build}`,
  }));
};

const pushApps = async (ip?: string) => {
  const targets = [...clients].filter((client) => ip === undefined || client.ip === ip);
  await Promise.all(
    targets.map(async (client) => {
      send(client, "apps", await appsFor(client.ip));
    }),
  );
};

const pushInstall = (ip: string, app: App, step: Step, sent: number) => {
  for (const client of clients) {
    if (client.ip === ip) {
      send(client, "install", { build: app.build, id: app.id, sent, size: app.size, step });
    }
  }
};

const megabytes = (bytes: number) => `${(bytes / 1e6).toFixed(1)} MB`;

const sendIpa = (req: IncomingMessage, res: ServerResponse, app: App, ip: string) => {
  const { size } = app;
  const range = /^bytes=(\d+)-(\d*)$/u.exec(req.headers.range ?? "");
  const start = Number(range?.[1] ?? "0");
  const end = range?.[2] === undefined || range[2] === "" ? size - 1 : Number(range[2]);
  res.setHeader("accept-ranges", "bytes");
  res.setHeader("content-length", end - start + 1);
  res.setHeader("content-type", "application/octet-stream");

  if (range) {
    res.setHeader("content-range", `bytes ${start}-${end}/${size}`);
  }

  res.writeHead(range ? 206 : 200);

  const what = `${app.name} ${app.build}`;

  if (req.method === "HEAD") {
    log(ip, `checked ${what} before downloading it`);
    res.end();

    return;
  }

  const began = Date.now();
  let sent = start;
  let told = 0;
  log(ip, `downloading ${what}${start > 0 ? ` from ${megabytes(start)}` : ""}: Install was tapped`);
  pushInstall(ip, app, "downloading", sent);

  const file = createReadStream(ipaPath(app.id, app.build), { end, start });
  file.on("data", (chunk) => {
    sent += chunk.length;

    if (Date.now() - told > 150) {
      told = Date.now();
      pushInstall(ip, app, "downloading", sent);
    }
  });
  file.pipe(res);
  res.on("close", () => {
    const seconds = ((Date.now() - began) / 1000).toFixed(1);

    if (sent === size && res.writableFinished) {
      pushInstall(ip, app, "downloaded", sent);
      void (async () => {
        log(ip, `downloaded ${what} (${megabytes(size)} in ${seconds}s): iOS installs it now`);
        await setPhoneBuild(ip, app.id, app.build);
        await pushApps(ip);
      })();
    } else {
      pushInstall(ip, app, "stopped", sent);
      log(ip, `stopped downloading ${what} at ${megabytes(sent)} of ${megabytes(size)} after ${seconds}s`);
    }
  });
};

const Report = z.object({
  build: z.number().optional(),
  detail: z.string().optional(),
  event: z.string(),
  id: z.string().optional(),
});

const readBody = async (req: IncomingMessage) => {
  const chunks: Buffer[] = [];

  for await (const chunk of req) {
    if (chunk instanceof Buffer) {
      chunks.push(chunk);
    }
  }

  return Buffer.concat(chunks).toString();
};

const json = (res: ServerResponse, data: PhoneApp[] | { ok: true }) => {
  res.writeHead(200, { "cache-control": "no-store", "content-type": "application/json" });
  res.end(JSON.stringify(data));
};

const events = async (req: IncomingMessage, res: ServerResponse, ip: string) => {
  res.writeHead(200, { "cache-control": "no-store", "content-type": "text/event-stream" });
  const client = { ip, res };

  clients.add(client);

  const beat = setInterval(() => {
    res.write(": beat\n\n");
  }, 20_000);

  req.on("close", () => {
    clearInterval(beat);
    clients.delete(client);
  });
  send(client, "apps", await appsFor(ip));
};

const report = async (req: IncomingMessage, res: ServerResponse, ip: string) => {
  const { event, id, build, detail } = Report.parse(JSON.parse(await readBody(req)));
  log(ip, `hangar ${[event, id, build, detail].filter((part) => part !== undefined).join(" ")}`);

  if (event === "opened" && id !== undefined && build !== undefined) {
    await setPhoneBuild(ip, id, build);
    await pushApps(ip);
  }

  json(res, { ok: true });
};

const appFile = async (req: IncomingMessage, res: ServerResponse, ip: string, path: string) => {
  const [, kind, id, file, rest] = path.split("/");
  const app = kind === "apps" && id !== undefined ? await getApp(id) : undefined;

  if (app === undefined) {
    res.writeHead(404).end();

    return;
  }

  if (file === "icon.png" && app.icon) {
    res.writeHead(200, { "cache-control": "max-age=31536000", "content-type": "image/png" });
    res.end(await readFile(iconPath(app.id)));

    return;
  }

  if (file === `${app.build}` && rest === "manifest.plist") {
    log(ip, `asked to install ${app.name} ${app.build}: iOS shows its Install alert`);
    pushInstall(ip, app, "asked", 0);
    res.writeHead(200, { "cache-control": "no-store", "content-type": "application/xml" });
    res.end(manifest(app));

    return;
  }

  const build = Number(/^(\d+)\.ipa$/u.exec(file ?? "")?.[1]);
  const found = Number.isNaN(build) ? undefined : await stat(ipaPath(app.id, build)).catch(() => null);

  if (found === undefined || found === null) {
    res.writeHead(404).end();

    return;
  }

  sendIpa(req, res, { ...app, build, size: found.size }, ip);
};

const route = async (req: IncomingMessage, res: ServerResponse) => {
  const ip = clientIp(req);
  const path = new URL(req.url ?? "/", "http://hangar").pathname;

  if (path === "/") {
    res.writeHead(200, { "cache-control": "no-store", "content-type": "text/html; charset=utf-8" });
    res.end(page(await listApps()));
  } else if (path === "/apps") {
    json(res, await appsFor(ip));
  } else if (path === "/events") {
    await events(req, res, ip);
  } else if (path === "/log" && req.method === "POST") {
    await report(req, res, ip);
  } else {
    await appFile(req, res, ip, path);
  }
};

const handle = async (req: IncomingMessage, res: ServerResponse) => {
  try {
    await route(req, res);
  } catch (error) {
    if (!res.headersSent) {
      res.writeHead(500);
    }

    res.end();
    throw error;
  }
};

export const serve = async () => {
  if (base === "") {
    throw new Error("HANGAR_URL isn't set: it's the address hangar is served at, like https://<host>/hangar");
  }

  await mkdir(appsDir, { recursive: true });
  let pending: NodeJS.Timeout | undefined;
  watch(appsDir, { recursive: true }, (_event, file) => {
    if (file?.endsWith("app.json") === true) {
      clearTimeout(pending);
      pending = setTimeout(() => {
        pushApps().catch(console.error);
      }, 200);
    }
  });
  createServer((req, res) => {
    handle(req, res).catch(console.error);
  }).listen(port, "127.0.0.1", () => {
    console.log(`hangar is serving ${base} on port ${port}`);
  });
};
