import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const operationalInputScript =
  process.env.AP_OPERATIONAL_INPUT_SCRIPT ||
  resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/ap-operational-input.sh");

export const AUTOPILOT_CURRENT_OPERATIONAL_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-autopilot",
  "launch-brief",
] as const;

export type AutopilotCurrentOperationalKind =
  (typeof AUTOPILOT_CURRENT_OPERATIONAL_KINDS)[number];

function runOperationalInputCommand(
  command: "encode" | "classify" | "kind",
  content: string,
  kind?: AutopilotCurrentOperationalKind,
): string | undefined {
  const args = command === "encode" ? [command, kind ?? ""] : [command];
  const result = spawnSync(operationalInputScript, args, {
    encoding: "utf8",
    input: content,
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) return undefined;
  return command === "classify" ? result.stdout.replace(/\n$/, "") : result.stdout;
}

export function encodeAutopilotOperationalInput(
  kind: AutopilotCurrentOperationalKind,
  content: string,
): string {
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) {
    throw new Error(`could not encode Autopilot operational input kind ${kind}`);
  }
  return encoded;
}

export function classifyAutopilotOperationalText(content: string): string | undefined {
  return runOperationalInputCommand("classify", content);
}

export function classifyAutopilotCurrentOperationalText(
  content: string,
): string | undefined {
  return runOperationalInputCommand("kind", content);
}
