/// <reference lib="webworker" />
import { simplifyNavigationGeometry } from "../core/navigation-lod-kernel";
import type { NavigationLodInput } from "../core/navigation-lod-kernel";
self.onmessage = async ({ data }: { data: NavigationLodInput }) => {
  try {
    const result = await simplifyNavigationGeometry(data);
    self.postMessage(
      { id: data.id, result },
      result ? [result.indices.buffer] : [],
    );
  } catch (error) {
    self.postMessage({
      id: data.id,
      error: error instanceof Error ? error.message : String(error),
    });
  }
};
