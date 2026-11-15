import { spawn } from "node:child_process";
import { once } from "node:events";
import { createReadStream } from "node:fs";

import { z } from "zod";

import { autoInstalls, downloaded, ipaPath, listApps, opened, runs } from "./store.ts";
import type { App } from "./store.ts";

const mac = process.env.HANGAR_MAC ?? "";

class MacError extends Error {
  override name = "MacError";
  detail: string;

  constructor(message: string, detail = "") {
    super(message);
    this.detail = detail;
  }
}

const onMac = async (script: string, ipa?: string) => {
  const ssh = spawn("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", mac, script]);
  let out = "";
  let err = "";
  ssh.stdout.on("data", (chunk: Buffer) => {
    out += chunk.toString();
  });
  ssh.stderr.on("data", (chunk: Buffer) => {
    err += chunk.toString();
  });

  if (ipa === undefined) {
    ssh.stdin.end();
  } else {
    createReadStream(ipa).pipe(ssh.stdin);
  }

  const [code] = z
    .tuple([z.number().nullable()])
    .rest(z.unknown())
    .parse(await once(ssh, "close"));

  if (code === 0) {
    return out;
  }

  if (code === 255) {
    throw new MacError("The Mac isn't answering", err.trim());
  }

  throw new MacError("The Mac can't reach this phone", err.trim().split("\n").slice(-3).join(" "));
};

const Devices = z.object({
  result: z.object({
    devices: z.array(
      z.object({
        properties: z
          .object({
            hardware: z
              .object({
                fidelity: z.string().optional(),
                productType: z.string().optional(),
                udid: z.string().regex(/^[\w-]+$/u),
              })
              .optional(),
          })
          .optional(),
      }),
    ),
  }),
});

const findPhone = async (model: string) => {
  const { result } = Devices.parse(
    JSON.parse(await onMac("xcrun devicectl list devices --quiet --json-output /dev/stdout")),
  );

  const phone = result.devices
    .map((device) => device.properties?.hardware)
    .find((hardware) => hardware?.fidelity === "physical" && hardware.productType === model);

  if (phone === undefined) {
    throw new MacError("The Mac doesn't know this phone");
  }

  return phone.udid;
};

const Installed = z.object({
  result: z.object({ apps: z.array(z.object({ bundleIdentifier: z.string(), bundleVersion: z.string() })) }),
});

const installedOn = async (udid: string) => {
  const { result } = Installed.parse(
    JSON.parse(
      await onMac(`xcrun devicectl device info apps --device ${udid} --quiet --json-output /dev/stdout`),
    ),
  );

  return new Map(result.apps.map((app) => [app.bundleIdentifier, Number(app.bundleVersion)]));
};

const installOn = async (udid: string, app: App) => {
  await onMac(
    `d=$(mktemp -d) && cat > "$d/app.ipa" && xcrun devicectl device install app --quiet --device ${udid} "$d/app.ipa"; s=$?; rm -rf "$d"; exit $s`,
    ipaPath(app.id, app.build),
  );
};

const isHangar = (app: App) => app.id.endsWith(".hangar");

const isOn = async (ip: string) => mac !== "" && (await autoInstalls.get(ip))?.on === true;

const pending = async (ip: string) => {
  const [apps, phone, downloads] = await Promise.all([listApps(), opened.get(ip), downloaded.get(ip)]);

  return apps
    .filter(
      (app) =>
        !runs(
          app,
          app.exact === true ? (phone[app.id] ?? 0) : Math.max(phone[app.id] ?? 0, downloads[app.id] ?? 0),
        ),
    )
    .toSorted((a, b) => Number(isHangar(a)) - Number(isHangar(b)));
};

export const autoInstaller = (log: (ip: string, line: string) => void) => {
  let listener: ((ip: string) => void) | undefined;
  const states = new Map<string, { installing: string | null; problem: string | null }>();
  const busy = new Set<string>();
  const again = new Set<string>();

  const stateFor = (ip: string) => {
    const state = states.get(ip) ?? { installing: null, problem: null };
    states.set(ip, state);

    return state;
  };

  const changed = (ip: string) => {
    listener?.(ip);
  };

  const onChange = (fn: (ip: string) => void) => {
    listener = fn;
  };

  const status = async (ip: string) => {
    const on = await isOn(ip);
    const { installing, problem } = stateFor(ip);
    const queue = on ? (await pending(ip)).map((app) => app.id) : [];
    const stuck = queue.length > 0 && installing === null ? problem : null;

    return { available: mac !== "", installing, on, problem: stuck, queue: stuck === null ? queue : [] };
  };

  const install = async (ip: string, udid: string, app: App, has: number) => {
    if (runs(app, has)) {
      await opened.set(ip, app.id, has);

      return;
    }

    if (!(await isOn(ip))) {
      return;
    }

    const state = stateFor(ip);
    state.installing = app.id;
    state.problem = null;
    changed(ip);
    const began = Date.now();
    log(ip, `installing ${app.name} ${app.build} on its own, from the Mac`);
    await installOn(udid, app);
    log(ip, `installed ${app.name} ${app.build} on its own in ${((Date.now() - began) / 1000).toFixed(1)}s`);
    await opened.set(ip, app.id, app.build);
    state.installing = null;
    changed(ip);
  };

  const syncOnce = async (ip: string) => {
    const setting = await autoInstalls.get(ip);
    const apps = await pending(ip);

    if (!(await isOn(ip)) || setting === undefined || apps.length === 0) {
      return;
    }

    const state = stateFor(ip);

    try {
      const udid = await findPhone(setting.model);
      const installed = await installedOn(udid);

      for (const app of apps) {
        // oxlint-disable-next-line eslint/no-await-in-loop -- one at a time, so hangar, last, updates itself after the rest
        await install(ip, udid, app, installed.get(app.id) ?? 0);
      }

      state.problem = null;
    } catch (error) {
      if (!(error instanceof MacError)) {
        throw error;
      }

      state.problem = error.message;
      log(
        ip,
        `couldn't install on its own: ${error.message}${error.detail === "" ? "" : ` (${error.detail})`}`,
      );
    } finally {
      state.installing = null;
      changed(ip);
    }
  };

  const sync = async (ip: string): Promise<void> => {
    if (busy.has(ip)) {
      again.add(ip);

      return;
    }

    busy.add(ip);

    try {
      await syncOnce(ip);
    } finally {
      busy.delete(ip);
    }

    if (again.delete(ip)) {
      await sync(ip);
    }
  };

  const syncAll = async () => {
    await Promise.all(Object.keys(await autoInstalls.all()).map(sync));
  };

  const set = async (ip: string, on: boolean, model: string) => {
    await autoInstalls.set(ip, { model, on });
    log(ip, on ? "installs builds on their own" : "installs builds when Update is tapped");
    changed(ip);
    await sync(ip);
  };

  return { onChange, set, status, sync, syncAll };
};
