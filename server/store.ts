import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

import { z } from "zod";

import { readIpa } from "./ipa.ts";

const App = z.object({
  build: z.number(),
  exact: z.boolean().optional(),
  icon: z.boolean(),
  id: z.string(),
  name: z.string(),
  notes: z.string(),
  published: z.string(),
  size: z.number(),
  version: z.string(),
});

export type App = z.infer<typeof App>;

// After a rollback the phone runs only the exact build hangar holds; otherwise any build as new or newer.
export const runs = (app: App, has: number) => (app.exact === true ? has === app.build : has >= app.build);

export const home = process.env.HANGAR_DIR ?? path.join(homedir(), ".local/share/hangar");
export const appsDir = path.join(home, "apps");
export const folder = (id: string) => path.join(appsDir, id);
export const ipaPath = (id: string, build: number) => path.join(folder(id), `${build}.ipa`);
export const iconPath = (id: string) => path.join(folder(id), "icon.png");

const writeAtomically = async (to: string, data: string | Uint8Array) => {
  await writeFile(`${to}.part`, data);
  await rename(`${to}.part`, to);
};

const readJson = async <T>(file: string, schema: z.ZodType<T>) => {
  const text = await readFile(file, "utf-8").catch(() => null);

  return text === null ? undefined : schema.parse(JSON.parse(text));
};

export const getApp = async (id: string) => await readJson(path.join(folder(id), "app.json"), App);

export const listApps = async () => {
  const ids = await readdir(appsDir).catch(() => []);
  const apps = await Promise.all(ids.map(getApp));

  return apps.filter((app) => app !== undefined).toSorted((a, b) => a.name.localeCompare(b.name));
};

export const put = async (file: string, notes: string) => {
  const bytes = await readFile(file);
  const ipa = readIpa(bytes);
  const was = await getApp(ipa.id);

  if (was !== undefined && was.build > ipa.build) {
    throw new Error(`${ipa.name} ${ipa.build} is older than build ${was.build}, which hangar already has`);
  }

  await mkdir(folder(ipa.id), { recursive: true });
  await writeAtomically(ipaPath(ipa.id, ipa.build), bytes);

  if (ipa.icon !== undefined) {
    await writeAtomically(iconPath(ipa.id), ipa.icon);
  }

  const app: App = {
    build: ipa.build,
    icon: ipa.icon !== undefined || was?.icon === true,
    id: ipa.id,
    name: ipa.name,
    notes,
    published: new Date().toISOString(),
    size: bytes.length,
    version: ipa.version,
  };

  await writeAtomically(path.join(folder(ipa.id), "app.json"), JSON.stringify(app, null, 2));

  const keep = new Set([`${ipa.build}.ipa`, `${was?.build}.ipa`]);
  const stale = (await readdir(folder(ipa.id))).filter((name) => name.endsWith(".ipa") && !keep.has(name));
  await Promise.all(
    stale.map(async (name) => {
      await rm(path.join(folder(ipa.id), name));
    }),
  );

  return app;
};

export const rollback = async (id: string) => {
  const app = await getApp(id);

  const other = (await readdir(folder(id)).catch(() => []))
    .map((name) => Number(/^(\d+)\.ipa$/u.exec(name)?.[1]))
    .find((build) => !Number.isNaN(build) && build !== app?.build);

  if (app === undefined || other === undefined) {
    throw new Error(`hangar holds no other build of ${id} to go back to`);
  }

  const bytes = await readFile(ipaPath(id, other));

  const back: App = {
    ...app,
    build: other,
    exact: true,
    notes: `Back to build ${other} from ${app.build}`,
    published: new Date().toISOString(),
    size: bytes.length,
    version: readIpa(bytes).version,
  };

  await writeAtomically(path.join(folder(id), "app.json"), JSON.stringify(back, null, 2));

  return { from: app, to: back };
};

const record = <T>(file: string, value: z.ZodType<T>) => {
  const at = path.join(home, file);
  let all: Record<string, T> | undefined;

  const load = async () => {
    all ??= (await readJson(at, z.record(z.string(), value))) ?? {};

    return all;
  };

  return {
    all: load,
    get: async (ip: string) => (await load())[ip],
    set: async (ip: string, data: T) => {
      const records = await load();
      records[ip] = data;
      mkdirSync(home, { recursive: true });
      writeFileSync(`${at}.part`, JSON.stringify(records, null, 2));
      renameSync(`${at}.part`, at);
    },
  };
};

const phoneRecord = (file: string) => {
  const builds = record(file, z.record(z.string(), z.number()));

  return {
    get: async (ip: string) => (await builds.get(ip)) ?? {},
    set: async (ip: string, id: string, build: number) => {
      await builds.set(ip, { ...(await builds.get(ip)), [id]: build });
    },
  };
};

export const opened = phoneRecord("phones.json");
export const downloaded = phoneRecord("downloads.json");
export const autoInstalls = record("auto.json", z.object({ model: z.string(), on: z.boolean() }));
