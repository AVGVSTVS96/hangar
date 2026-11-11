import { parseArgs } from "node:util";

import { serve } from "./serve.ts";
import { put } from "./store.ts";

const usage = `usage:
  hangar put <signed .ipa> [--notes '<one line on what changed>']
  hangar serve`;

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: { notes: { default: "", type: "string" } },
});

const [command, file] = positionals;

try {
  if (command === "put" && file !== undefined) {
    const app = await put(file, values.notes);
    console.log(`${app.name} ${app.build} is on hangar`);
  } else if (command === "serve") {
    await serve();
  } else {
    console.error(usage);
    process.exitCode = 2;
  }
} catch (error) {
  console.error(`hangar ${command} ${file ?? ""}: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
