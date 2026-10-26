// Where a conversation goes as items arrive (src/friends/follow.ts): sending takes it to its end from wherever the
// person scrolled; the friend's messages arriving below one scrolled up are counted for the pill, in the helper's words.
import { describe, expect, it } from "vitest";
import { NO_FOLLOW, noteItems, pillTitle } from "../src/friends/follow";

const day = { item_id: "d_1", kind: "day" };
const said = (id: string, direction: "in" | "out", kind = "message") => ({
  item_id: id,
  kind,
  direction,
});
const base = [day, said("m_1", "in"), said("m_2", "out")];

describe("following a conversation", () => {
  it("the first snapshot counts nothing", () => {
    const { follow, toEnd } = noteItems(NO_FOLLOW, base, false);
    expect(toEnd).toBe(false);
    expect(follow).toEqual({ newest: "m_2", unseen: 0, firstUnseen: null });
  });

  it("the friend's messages below a history scrolled up are counted, the first remembered", () => {
    let { follow } = noteItems(NO_FOLLOW, base, true);
    ({ follow } = noteItems(follow, [...base, said("m_3", "in")], false));
    expect(follow.unseen).toBe(1);
    ({ follow } = noteItems(
      follow,
      [
        ...base,
        said("m_3", "in"),
        said("t_4", "in", "transfer"),
        said("m_5", "in"),
      ],
      false,
    ));
    expect(follow).toEqual({ newest: "m_5", unseen: 3, firstUnseen: "m_3" });
  });

  it("at the end nothing is counted", () => {
    const first = noteItems(NO_FOLLOW, base, true).follow;
    expect(
      noteItems(first, [...base, said("m_3", "in")], true).follow.unseen,
    ).toBe(0);
  });

  it("sending goes to the end from anywhere and clears the count", () => {
    let { follow } = noteItems(NO_FOLLOW, base, true);
    ({ follow } = noteItems(follow, [...base, said("m_3", "in")], false));
    const sent = noteItems(
      follow,
      [...base, said("m_3", "in"), said("m_4", "out")],
      false,
    );
    expect(sent.toEnd).toBe(true);
    expect(sent.follow.unseen).toBe(0);
  });

  it("earlier items loaded above, or another history, count nothing", () => {
    const { follow } = noteItems(NO_FOLLOW, base, false);
    expect(
      noteItems(follow, [said("m_0", "in"), ...base], false).follow.unseen,
    ).toBe(0);
    expect(noteItems(follow, [said("x_1", "in")], false).follow.unseen).toBe(0);
  });

  it("the pill says it in the helper's words, or not at all", () => {
    const strings = {
      new_message: "New message ↓",
      new_messages: "{count} new messages ↓",
    };
    expect(pillTitle(strings, 0)).toBeNull();
    expect(pillTitle(strings, 1)).toBe("New message ↓");
    expect(pillTitle(strings, 3)).toBe("3 new messages ↓");
    expect(pillTitle({}, 2)).toBeNull();
  });
});
