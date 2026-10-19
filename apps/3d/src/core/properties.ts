import * as T from "three";
import { cad } from "./cad-client";
import { analyzeMeshFeature } from "./mesh-features";
import type { FeatureProperties, ModelDocument, Pick, Vec3 } from "./types";
export async function featureProperties(
  doc: ModelDocument,
  pick: Pick,
): Promise<FeatureProperties> {
  const data = doc.geometries.get(pick.geometryId)!;
  const matrix = new T.Matrix4().fromArray(pick.matrix);
  const scale = new T.Vector3().setFromMatrixScale(matrix);
  const uniform =
    Math.abs(scale.x - scale.y) < 1e-7 && Math.abs(scale.x - scale.z) < 1e-7;
  let props: FeatureProperties = { exact: false };
  if (doc.exactModelId && pick.exactHandle && pick.kind !== "point")
    props = await cad.properties(doc.exactModelId, pick);
  else if (data.geometry.userData.drawing)
    props = { ...data.geometry.userData.drawing };
  else if (pick.triangleIndex !== undefined) {
    const feature = analyzeMeshFeature(data.geometry, pick.triangleIndex);
    if (feature)
      props = { ...feature.properties, perimeter: feature.perimeter };
    else {
      const g = data.geometry,
        index = g.index,
        i = pick.triangleIndex * 3;
      const a = new T.Vector3().fromBufferAttribute(
          g.attributes.position,
          index ? index.getX(i) : i,
        ),
        b = new T.Vector3().fromBufferAttribute(
          g.attributes.position,
          index ? index.getX(i + 1) : i + 1,
        ),
        c = new T.Vector3().fromBufferAttribute(
          g.attributes.position,
          index ? index.getX(i + 2) : i + 2,
        );
      props = {
        exact: false,
        family: "triangle",
        area: new T.Triangle(a, b, c).getArea(),
        center: new T.Triangle(a, b, c)
          .getMidpoint(new T.Vector3())
          .toArray() as Vec3,
      };
    }
  }
  if (props.center)
    props.center = new T.Vector3()
      .fromArray(props.center)
      .applyMatrix4(matrix)
      .toArray() as Vec3;
  if (uniform) {
    for (const key of ["length", "radius", "diameter", "perimeter"] as const)
      if (props[key] !== undefined) props[key]! *= scale.x;
    if (props.area !== undefined) props.area *= scale.x * scale.x;
  } else {
    props.exact = false;
    props.radius = undefined;
    props.diameter = undefined;
    props.length = undefined;
    props.area = undefined;
    props.perimeter = undefined;
    if (data.lines) {
      const points = data.geometry.attributes.position;
      let length = 0;
      for (let i = 1; i < points.count; i++)
        length += new T.Vector3()
          .fromBufferAttribute(points, i)
          .applyMatrix4(matrix)
          .distanceTo(
            new T.Vector3()
              .fromBufferAttribute(points, i - 1)
              .applyMatrix4(matrix),
          );
      props.length = length;
    }
  }
  return props;
}

/** Direction of a picked line or triangle normal, in original assembly coordinates. */
export function featureDirection(
  doc: ModelDocument,
  pick: Pick,
): T.Vector3 | undefined {
  const data = doc.geometries.get(pick.geometryId);
  if (!data) return;
  const matrix = new T.Matrix4().fromArray(pick.matrix),
    g = data.geometry;
  if (pick.kind === "edge") {
    const points = data.topology?.edges.find(
      (e) => e.id === pick.elementId,
    )?.points;
    const attribute = g.attributes.position;
    const a = points
      ? new T.Vector3().fromArray(points, 0)
      : data.lines
        ? new T.Vector3().fromBufferAttribute(attribute, 0)
        : undefined;
    const b = points
      ? new T.Vector3().fromArray(points, points.length - 3)
      : data.lines
        ? new T.Vector3().fromBufferAttribute(attribute, attribute.count - 1)
        : undefined;
    if (a && b && a.distanceToSquared(b) > 1e-12)
      return b.applyMatrix4(matrix).sub(a.applyMatrix4(matrix)).normalize();
  } else if (pick.kind === "face" && pick.triangleIndex !== undefined) {
    const i = pick.triangleIndex * 3,
      index = g.index;
    const a = new T.Vector3()
        .fromBufferAttribute(g.attributes.position, index ? index.getX(i) : i)
        .applyMatrix4(matrix),
      b = new T.Vector3()
        .fromBufferAttribute(
          g.attributes.position,
          index ? index.getX(i + 1) : i + 1,
        )
        .applyMatrix4(matrix),
      c = new T.Vector3()
        .fromBufferAttribute(
          g.attributes.position,
          index ? index.getX(i + 2) : i + 2,
        )
        .applyMatrix4(matrix);
    return new T.Triangle(a, b, c).getNormal(new T.Vector3());
  }
}
