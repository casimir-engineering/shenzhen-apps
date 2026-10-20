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
  /** Android: updates come as APKs that Android installs after the person confirms; the channel is fixed. */
  platform?: "android";
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
