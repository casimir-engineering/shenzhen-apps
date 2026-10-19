// The open model as a project file for Friends: Send project to a friend and the `#` attachment both stage it
// through the main process, which writes it only under a plain name of at most 200 bytes that does not start with a
// dot (electron/friends/host.cjs). The name is made to fit here, so a long or dotted model name still sends.
import type { FriendsBridge } from "./bridge";
import type { OutgoingFile } from "./drops";

export const MAX_STAGED_NAME_BYTES = 200;
const EXTENSION = ".sz3d";

/** Shown when the open model could not be made ready to send. */
export const STAGE_FAILED =
  "Could not get this model ready to send. Try again.";

const bytes = (text: string) => new TextEncoder().encode(text).length;

/** Whole characters (grapheme clusters where the runtime knows them), so a trim never splits one. */
function characters(text: string): string[] {
  const Segmenter = (Intl as { Segmenter?: typeof Intl.Segmenter }).Segmenter;
  if (Segmenter)
    return Array.from(new Segmenter().segment(text), (part) => part.segment);
  return Array.from(text);
}

/** `name` as the project file Friends sends: no folder separators, no leading dot, `.sz3d`, at most 200 bytes. */
export function stagedProjectName(name: string): string {
  let base = name
    .replace(/\.sz3d$/i, "")
    .replace(/[/\\\0]/g, "-")
    .replace(/^[.\s]+/, "");
  const room = MAX_STAGED_NAME_BYTES - EXTENSION.length;
  if (bytes(base) > room) {
    let kept = "";
    let size = 0;
    for (const character of characters(base)) {
      const next = bytes(character);
      if (size + next > room) break;
      kept += character;
      size += next;
    }
    base = kept;
  }
  base = base.trimEnd();
  return (base || "Model") + EXTENSION;
}

/**
 * Builds the open model and stages it: the file Friends sends, named as the friend will see it. A failure is told to
 * `onError` in the app's own sentence, never as the error the bridge raised, and then rethrown.
 */
export async function stageProject(
  bridge: Pick<FriendsBridge, "stage">,
  build: () => Promise<{ blob: Blob; name: string }>,
  onError: (message: string) => void,
): Promise<OutgoingFile> {
  try {
    const { blob, name } = await build();
    const fitted = stagedProjectName(name);
    return {
      path: await bridge.stage(
        fitted,
        new Uint8Array(await blob.arrayBuffer()),
      ),
      display_name: fitted,
    };
  } catch (failure) {
    onError(STAGE_FAILED);
    throw failure;
  }
}
