// redact.mjs — the one place where the exit-test drivers shorten a URL or a
// mail body before they log it.
//
// hosted is a public repository, and its workflow logs are public. A setup
// link, an invite link or a Checkout URL carries a one-time code or a session
// state in its query. So a driver never logs a query value in full.

/** safeURL cuts the value of each query parameter to four characters and drops the fragment. */
export function safeURL(raw) {
  try {
    const u = new URL(raw);
    for (const [k, v] of u.searchParams) u.searchParams.set(k, v.length > 4 ? `${v.slice(0, 4)}…` : v);
    // A fragment is opaque state. It tells the reader nothing.
    u.hash = "";
    return u.toString();
  } catch {
    return "<not a URL>";
  }
}

/** safeText applies safeURL to each http(s) URL in a text, such as a mail body. */
export function safeText(text) {
  return String(text ?? "").replace(/https?:\/\/[^\s"'<>]+/g, (m) => safeURL(m));
}
