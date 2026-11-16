import { parseArgs } from "node:util";

import { serve } from "./serve.ts";
import { autoInstalls, put, rollback } from "./store.ts";

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
    const auto = Object.values(await autoInstalls.all()).filter(({ on }) => on).length;
    console.log(
      `${app.name} ${app.build} is on hangar: ${
        auto > 0
          ? `it installs by itself on the ${auto === 1 ? "phone" : `${auto} phones`} with Automatic installs on`
          : "it installs when Update is tapped in hangar, since no phone has Automatic installs on"
      }`,
    );
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
