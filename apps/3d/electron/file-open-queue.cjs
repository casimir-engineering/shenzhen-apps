/** OS-delivered batches belong to one window; only startup batches are unassigned. */
function createFileOpenQueue() {
  const batches = [];
  return {
    push(paths, targetId) {
      batches.push({ paths, targetId });
      if (batches.length > 16) batches.shift();
    },
    restore(paths, targetId) {
      batches.unshift(...paths.map((files) => ({ paths: files, targetId })));
      if (batches.length > 16) batches.splice(16);
    },
    take(senderId, primaryId) {
      const result = [];
      for (let i = 0; i < batches.length;) {
        const batch = batches[i];
        if ((batch.targetId ?? primaryId) === senderId) {
          result.push(batch.paths);
          batches.splice(i, 1);
        } else i++;
      }
      return result;
    },
  };
}
module.exports = { createFileOpenQueue };
