import { createRoot } from "react-dom/client";
import App from "./App";
import { installNativeUpdates } from "./core/native-updates";
import "./styles.css";
// Before the first render: the footer offers Updates only where window.shenzhenUpdates exists.
installNativeUpdates();
createRoot(document.getElementById("root")!).render(<App />);

if (
  import.meta.env.PROD &&
  /^https?:$/.test(window.location.protocol) &&
  "serviceWorker" in navigator &&
  !(window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
) {
  const afterLoad = () => {
    // Give the shell two painted frames and the first import a head start.
    // Idle scheduling is bounded so offline installation also starts on busy pages.
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        window.setTimeout(() => {
          const register = () => {
            void navigator.serviceWorker.register("./sw.js").catch(() => {
              /* Offline installation may be unavailable in private browsing. */
            });
          };
          if ("requestIdleCallback" in window) {
            window.requestIdleCallback(register, { timeout: 2000 });
          } else {
            register();
          }
        }, 4000);
      }),
    );
  };
  if (document.readyState === "complete") {
    afterLoad();
  } else {
    window.addEventListener("load", afterLoad, { once: true });
  }
}
