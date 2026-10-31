import {
  startRegistration,
  startAuthentication,
  browserSupportsWebAuthn,
  WebAuthnAbortService,
  type PublicKeyCredentialCreationOptionsJSON,
  type PublicKeyCredentialRequestOptionsJSON,
} from "@simplewebauthn/browser";
export interface BrowserSessionState {
  authenticated: boolean;
  csrf: string;
  idleUntil?: number;
  absoluteUntil?: number;
  passkeys?: number;
}
/** Session cookies remain HttpOnly. Only a CSRF token and lifetime hints live in
 * this tab; no owner credential or browser auth state is written to storage. */
export class BrowserSession {
  private generation = 0;
  private requests = new Set<AbortController>();
  state: BrowserSessionState = { authenticated: false, csrf: "" };
  get supported(): boolean {
    return window.isSecureContext && browserSupportsWebAuthn();
  }
  clear(): void {
    this.generation++;
    for (const controller of this.requests) controller.abort();
    this.requests.clear();
    WebAuthnAbortService.cancelCeremony();
    this.state = { authenticated: false, csrf: "" };
  }
  touch(): void {
    if (this.state.authenticated)
      this.state.idleUntil = Math.min(
        this.state.absoluteUntil ?? 0,
        Date.now() + 30 * 60_000,
      );
  }
  async call<T>(path: string, body?: unknown, recovery?: string): Promise<T> {
    const generation = this.generation,
      controller = new AbortController(),
      timer = setTimeout(() => controller.abort(), 30000);
    this.requests.add(controller);
    try {
      const response = await fetch("/api/v1/auth" + path, {
        method: body === undefined ? "GET" : "POST",
        headers: {
          Accept: "application/json",
          ...(body === undefined
            ? {}
            : {
                "Content-Type": "application/json",
                "X-CloudNest-CSRF": this.state.csrf,
              }),
          ...(recovery ? { Authorization: "Bearer " + recovery } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        signal: controller.signal,
      });
      if (!response.ok) {
        if (response.status === 401)
          throw new Error(
            "Sign-in expired or could not be verified. Start again with your passkey.",
          );
        if (response.status === 429)
          throw new Error(
            "Too many sign-in attempts. Wait a minute before trying again.",
          );
        if (response.status === 403)
          throw new Error(
            "Browser security check failed. Reload this page before trying again.",
          );
        if (response.status === 404)
          throw new Error(
            "Passkey sign-in is not available on this deployment. Advanced owner access remains available.",
          );
        throw new Error(
          "Sign-in is unavailable. Check your connection and try again.",
        );
      }
      const reader = response.body?.getReader();
      if (!reader) throw new Error("Empty sign-in response.");
      const chunks: Uint8Array[] = [];
      let size = 0;
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        size += next.value.length;
        if (size > 65536) {
          await reader.cancel();
          throw new Error("Sign-in response exceeded its size limit.");
        }
        chunks.push(next.value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      if (generation !== this.generation)
        throw new Error("Sign-in was canceled.");
      return JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      ) as T;
    } finally {
      clearTimeout(timer);
      this.requests.delete(controller);
    }
  }
  private adopt(state: BrowserSessionState): BrowserSessionState {
    if (
      typeof state.authenticated !== "boolean" ||
      !/^[a-f0-9]{64}$/.test(state.csrf)
    )
      throw new Error("Invalid sign-in response.");
    this.state = state;
    return state;
  }
  async inspect(): Promise<BrowserSessionState> {
    return this.adopt(await this.call<BrowserSessionState>("/session"));
  }
  async signIn(): Promise<void> {
    if (!this.supported)
      throw new Error(
        "Passkeys require HTTPS and a supported browser. Use advanced owner access on this device.",
      );
    await this.inspect();
    const { options } = await this.call<{
      options: PublicKeyCredentialRequestOptionsJSON;
    }>("/login/options", {});
    try {
      const response = await startAuthentication({ optionsJSON: options });
      this.adopt(
        await this.call<BrowserSessionState>("/login/verify", response),
      );
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotAllowedError")
        throw new Error(
          "Passkey sign-in was canceled or timed out. Try again when you are ready.",
        );
      throw error;
    }
  }
  async register(recovery: string, label: string): Promise<void> {
    if (!this.supported)
      throw new Error(
        "Passkey enrollment requires HTTPS and a supported browser.",
      );
    await this.inspect();
    const { options } = await this.call<{
      options: PublicKeyCredentialCreationOptionsJSON;
    }>("/register/options", { label }, recovery);
    try {
      const response = await startRegistration({ optionsJSON: options });
      this.adopt(
        await this.call<BrowserSessionState>(
          "/register/verify",
          response,
          recovery,
        ),
      );
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotAllowedError")
        throw new Error(
          "Passkey setup was canceled or timed out. No passkey was enrolled.",
        );
      throw error;
    }
  }
  async signOut(all = false): Promise<void> {
    const csrf = this.state.csrf;
    this.clear();
    this.state.csrf = csrf;
    const response = this.call(all ? "/revoke-sessions" : "/logout", {});
    this.state = { authenticated: false, csrf: "" };
    try {
      await response;
    } finally {
      this.clear();
    }
  }
}
