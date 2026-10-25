/** The version this page was built as: package.json's, which vite.config.ts writes into index.html as
 * <meta name="shenzhen-3d-version">, where tools/release.sh checks it in every build it makes. */
export const builtVersion =
  document.querySelector<HTMLMetaElement>('meta[name="shenzhen-3d-version"]')
    ?.content ?? "";
