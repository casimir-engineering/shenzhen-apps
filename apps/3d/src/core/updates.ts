export interface UpdateState {
  supported: boolean;
  version: string;
  status:
    | "idle"
    | "checking"
    | "available"
    | "downloading"
    | "ready"
    | "installing"
    | "error"
    | "needs-auth";
  automatic: boolean;
  repository: string;
  /** "public" releases need no GitHub access; "private" ones do. */
  access: "public" | "private";
  prereleases: boolean;
  connected: boolean;
  availableVersion?: string;
  progress?: number;
  message: string;
  lastChecked?: number;
  /** Android: APKs that Android installs after the person confirms. Windows, Linux and iOS
   * (src-tauri/src/app_updates.rs): one release channel, and Update to X does it all. */
  platform?: "android" | "windows" | "linux" | "ios";
  /** The newer version is a package to download and install by hand (Linux deb and rpm). */
  downloadOnly?: boolean;
}
export interface UpdateBridge {
  getState(): Promise<UpdateState>;
  check(): Promise<UpdateState>;
  download(): Promise<UpdateState>;
  install(): Promise<UpdateState>;
  configure(
    value: Partial<
      Pick<UpdateState, "automatic" | "repository" | "prereleases">
    >,
  ): Promise<UpdateState>;
  connect(token: string): Promise<UpdateState>;
  disconnect(): Promise<UpdateState>;
  useGitHubCLI(): Promise<UpdateState>;
  subscribe(listener: (state: UpdateState) => void): () => void;
}
declare global {
  interface Window {
    shenzhenUpdates?: UpdateBridge;
  }
}
