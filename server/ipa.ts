import { parse } from "@plist/parse";
import { unzipSync } from "fflate";
import { z } from "zod";

export interface Ipa {
  id: string;
  name: string;
  build: number;
  version: string;
  icon: Uint8Array | undefined;
}

const Info = z.object({
  CFBundleDisplayName: z.string().optional(),
  CFBundleIconFile: z.string().optional(),
  CFBundleIconFiles: z.array(z.string()).default([]),
  CFBundleIcons: z
    .object({
      CFBundlePrimaryIcon: z.object({ CFBundleIconFiles: z.array(z.string()).default([]) }).optional(),
    })
    .optional(),
  CFBundleIdentifier: z.string().min(1, "its Info.plist has no CFBundleIdentifier"),
  CFBundleName: z.string().optional(),
  CFBundleShortVersionString: z.string().default(""),
  CFBundleURLTypes: z.array(z.object({ CFBundleURLSchemes: z.array(z.string()).default([]) })).default([]),
  CFBundleVersion: z
    .string()
    .regex(/^[1-9]\d*$/u, "hangar needs a CFBundleVersion that is a whole number going up with every build")
    .transform(Number),
});

type Info = z.infer<typeof Info>;

const topLevel = /^Payload\/[^/]+\.app\/[^/]+$/u;

const width = (png: Uint8Array) => {
  const bytes = Buffer.from(png);
  const at = bytes.indexOf("IHDR");

  return at === -1 ? 0 : bytes.readUInt32BE(at + 4);
};

const pickIcon = (info: Info, files: Record<string, Uint8Array>) => {
  const names = [
    ...(info.CFBundleIcons?.CFBundlePrimaryIcon?.CFBundleIconFiles ?? []),
    ...info.CFBundleIconFiles,
    ...(info.CFBundleIconFile === undefined ? [] : [info.CFBundleIconFile.replace(/\.png$/u, "")]),
  ];

  const icons = Object.entries(files)
    .filter(([path]) => path.endsWith(".png"))
    .filter(([path]) => names.some((name) => path.split("/").at(-1)?.startsWith(name) === true))
    .map(([, png]) => png);

  return icons.toSorted((a, b) => width(b) - width(a))[0];
};

const macMetadata = /(?:^|\/)(?:\._|__MACOSX\/)/u;

export const readIpa = (bytes: Uint8Array): Ipa => {
  let metadata: string | undefined;

  const files = unzipSync(bytes, {
    filter: (file) => {
      if (macMetadata.test(file.name)) {
        metadata ??= file.name;
      }

      return topLevel.test(file.name) && (file.name.endsWith("/Info.plist") || file.name.endsWith(".png"));
    },
  });

  if (metadata !== undefined) {
    throw new Error(
      `it holds macOS metadata files like ${metadata}, which iOS can reject as files outside the signature. Zip it with \`ditto -c -k --norsrc --noextattr --keepParent Payload <app>.ipa\``,
    );
  }

  const plist = Object.entries(files).find(([path]) => path.endsWith("/Info.plist"))?.[1];

  if (plist === undefined) {
    throw new Error("it has no Payload/<name>.app/Info.plist, so it isn't an iOS app");
  }

  const read = Info.safeParse(parse(new Uint8Array(plist).buffer));

  if (!read.success) {
    throw new Error(read.error.issues.map((issue) => issue.message).join("; "));
  }

  const info = read.data;
  const id = info.CFBundleIdentifier;
  const build = info.CFBundleVersion;
  const scheme = `${id}-${build}`;

  if (!info.CFBundleURLTypes.some((type) => type.CFBundleURLSchemes.includes(scheme))) {
    throw new Error(
      `it doesn't register the URL scheme ${scheme}. hangar opens it to know build ${build} is installed and to bring the app back, so add it to CFBundleURLTypes in the app's Info.plist`,
    );
  }

  return {
    build,
    icon: pickIcon(info, files),
    id,
    name: info.CFBundleDisplayName ?? info.CFBundleName ?? id,
    version: info.CFBundleShortVersionString,
  };
};
