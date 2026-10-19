import { describe, expect, it } from "vitest";
import {
  entityIndex,
  indexStep,
  refsOf,
  typeOf,
} from "../src/core/step/step-index";
import { parseRecords } from "../src/core/step/step-params";

const text = `ISO-10303-21;
HEADER;
FILE_NAME('a;b.step','',(''),(''),'','','');
ENDSEC;
DATA;
/* a comment with #99 and ; inside */
#1 = PRODUCT('it''s;#2','name','',(#3));
#3 = PRODUCT_CONTEXT('',#4,'mechanical');
#4 = ( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );
#10=TRIMMED_CURVE('',#3,(#4,PARAMETER_VALUE(0.)),(#4,PARAMETER_VALUE(1.5E1)),.T.,.PARAMETER.);
ENDSEC;
END-ISO-10303-21;
`;

describe("STEP index", () => {
  const index = indexStep(new TextEncoder().encode(text));
  it("finds entities, types and references outside strings and comments", () => {
    expect(index.count).toBe(4);
    expect([...index.ids]).toEqual([1, 3, 4, 10]);
    expect(typeOf(index, entityIndex(index, 1))).toBe("PRODUCT");
    expect(typeOf(index, entityIndex(index, 4))).toBe("(COMPLEX)");
    expect([...refsOf(index, entityIndex(index, 1))]).toEqual([3]);
    expect([...refsOf(index, entityIndex(index, 10))]).toEqual([3, 4, 4]);
    expect(entityIndex(index, 99)).toBe(-1);
  });
  it("parses strings, enums, typed values and complex records", () => {
    expect(parseRecords(index, entityIndex(index, 1))[0].args[0]).toEqual({
      str: "it's;#2",
    });
    expect(
      parseRecords(index, entityIndex(index, 4)).map((r) => r.type),
    ).toEqual(["LENGTH_UNIT", "NAMED_UNIT", "SI_UNIT"]);
    expect(parseRecords(index, entityIndex(index, 4))[2].args).toEqual([
      { enum: "MILLI" },
      { enum: "METRE" },
    ]);
    const trimmed = parseRecords(index, entityIndex(index, 10))[0].args;
    expect(trimmed[3]).toEqual([
      { ref: 4 },
      { typed: "PARAMETER_VALUE", args: [15] },
    ]);
    expect(trimmed[4]).toEqual({ enum: "T" });
  });
});
