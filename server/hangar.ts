import { parseArgs } from "node:util";

import { serve } from "./serve.ts";
import { put, rollback } from "./store.ts";

const usage = `usage:
  hangar put <signed .ipa> [--notes '<one line on what changed>']
  hangar rollback <bundle id>
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
  } else if (command === "rollback" && file !== undefined) {
    const { from, to } = await rollback(file);
    console.log(
      `${to.name} is back on build ${to.build} from ${from.build}; hangar rollback ${file} again goes forward`,
    );
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
