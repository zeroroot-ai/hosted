// ---------------------------------------------------------------------------
// mailsource.mjs — one reader for the mail of a test run, whatever the target
// (hosted#647).
//
// The signup driver runs against kind and against an AWS environment with the
// same steps. Only the place where the verification mail lands differs:
//
//   mailpit   kind: the chart's Mailpit sink, read over its HTTP API
//             (MAILPIT_URL).
//   s3        AWS: the test inbox of the environment. SES receives mail for
//             inbox.<env domain> and stores each message, raw, under mail/
//             in INBOX_BUCKET (substrate/gibson-bootstrap/inbox.tf). Read
//             with the ambient AWS credential of the run (the smoke driver
//             role) through the AWS CLI.
//
// Both return the same summary shape that test/lib/mailbox.mjs selects on:
// { ID, Subject, Created, To: [{ Address }] }, and body(ID) returns the
// decoded text and HTML of the message. A third target is a third branch
// here, never a second driver (ADR-0027).
// ---------------------------------------------------------------------------

import { execFileSync } from "node:child_process";
import process from "node:process";

/** The mail source the environment names. Throws when it names none or an unknown one. */
export function mailSourceFromEnv(env = process.env) {
  const kind = env.MAIL_SOURCE ?? "";
  if (kind === "mailpit") {
    const url = (env.MAILPIT_URL ?? "").replace(/\/+$/, "");
    if (!url) throw new Error("MAIL_SOURCE=mailpit needs MAILPIT_URL");
    return mailpitSource(url);
  }
  if (kind === "s3") {
    const bucket = env.INBOX_BUCKET ?? "";
    if (!bucket) throw new Error("MAIL_SOURCE=s3 needs INBOX_BUCKET");
    const sender = (env.MAIL_SENDER_DOMAIN ?? "").toLowerCase();
    if (!sender) throw new Error("MAIL_SOURCE=s3 needs MAIL_SENDER_DOMAIN: the inbox takes mail from anyone, so only the platform's own mail is read");
    return s3Source(bucket, env.AWS_REGION ?? env.AWS_DEFAULT_REGION ?? "us-east-1", sender);
  }
  throw new Error(`MAIL_SOURCE must be mailpit or s3, got ${JSON.stringify(kind)}`);
}

function mailpitSource(url) {
  return {
    kind: "mailpit",
    async list() {
      const resp = await fetch(`${url}/api/v1/messages?limit=200`).catch(() => null);
      if (!resp || !resp.ok) return [];
      const body = await resp.json();
      return body.messages ?? [];
    },
    async body(id) {
      const resp = await fetch(`${url}/api/v1/message/${encodeURIComponent(id)}`);
      if (!resp.ok) throw new Error(`mailpit message fetch: HTTP ${resp.status}`);
      const m = await resp.json();
      return `${m.Text ?? ""}\n${m.HTML ?? ""}`;
    },
  };
}

function aws(args) {
  return execFileSync("aws", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
}

function s3Source(bucket, region, senderDomain) {
  const raw = new Map();
  const refused = new Set();
  const fetchRaw = (key) => {
    if (!raw.has(key)) raw.set(key, aws(["s3", "cp", "--region", region, `s3://${bucket}/${key}`, "-"]));
    return raw.get(key);
  };
  return {
    kind: "s3",
    async list() {
      // A listing or a read that fails is an error, never an empty inbox:
      // a role that cannot read the mail must say so, not wait out 180 s.
      const listed = JSON.parse(aws(["s3api", "list-objects-v2", "--region", region, "--bucket", bucket,
        "--prefix", "mail/", "--output", "json"]) || "{}");
      const out = [];
      for (const o of listed.Contents ?? []) {
        if (o.Key.endsWith("AMAZON_SES_SETUP_NOTIFICATION")) continue;
        const raw = fetchRaw(o.Key);
        const why = mailVerdict(raw, senderDomain);
        if (why) {
          if (!refused.has(o.Key)) {
            refused.add(o.Key);
            const to = summary(o.Key, raw).To.map((t) => t.Address).join(",");
            console.log(`s3 inbox: ignored ${o.Key} to ${to}: ${why}`);
          }
          continue;
        }
        out.push(summary(o.Key, raw, o.LastModified));
      }
      return out;
    },
    async body(id) {
      return decodeBody(fetchRaw(id));
    },
  };
}

// ---------------------------------------------------------------------------
// Raw MIME (RFC 5322 / 2045), the subset a platform mail uses. Pure, selftested.
// ---------------------------------------------------------------------------

function splitHeaders(text) {
  const i = text.search(/\r?\n\r?\n/);
  const head = i < 0 ? text : text.slice(0, i);
  const body = i < 0 ? "" : text.slice(i).replace(/^\r?\n\r?\n/, "");
  // The FIRST value of each header: SES prepends its own headers (the
  // Authentication-Results of amazonses.com) above the sender's, so a sender
  // who writes a second one below cannot replace it (hosted#661 review).
  // count holds how often each header appears.
  const headers = {};
  const count = {};
  for (const line of head.replace(/\r?\n[ \t]+/g, " ").split(/\r?\n/)) {
    const c = line.indexOf(":");
    if (c <= 0) continue;
    const k = line.slice(0, c).trim().toLowerCase();
    count[k] = (count[k] ?? 0) + 1;
    if (!(k in headers)) headers[k] = line.slice(c + 1).trim();
  }
  return { headers, count, body };
}

function decodeWords(v) {
  return (v ?? "").replace(/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/g, (_, cs, enc, data) => {
    const buf = enc.toUpperCase() === "B"
      ? Buffer.from(data, "base64")
      : Buffer.from(data.replace(/_/g, " ").replace(/=([0-9A-Fa-f]{2})/g, (m, h) => String.fromCharCode(parseInt(h, 16))), "latin1");
    return buf.toString(/utf-?8/i.test(cs) ? "utf8" : "latin1");
  });
}

function addresses(v) {
  return (v ?? "").split(",").map((p) => {
    const m = p.match(/<([^>]+)>/);
    return { Address: (m ? m[1] : p).trim() };
  }).filter((a) => a.Address);
}

/**
 * mailVerdict: why a raw inbox message is or is not the platform's own mail.
 *
 * The test inbox takes mail from anyone (an SES receipt rule filters only by
 * recipient), and the driver follows the link it finds. SES writes its checks
 * into the stored message as an `Authentication-Results: amazonses.com; ...`
 * header (the X-SES-*-VERDICT names are fields of the SES event, not headers
 * of the stored mail: drill and promote runs of 2026-10-12 dropped every
 * message on them). A message counts only when:
 *   - SES saw spf=pass, and
 *   - SES saw a dkim=pass whose signing domain (header.d, or the domain of
 *     header.i) ALIGNS with the From domain: the From domain is that domain
 *     or a subdomain of it, and that domain has two labels at least. That is
 *     the DMARC relaxed alignment, so a sender's own valid signature does not
 *     vouch for a From on the platform domain (hosted#650 review), and
 *   - the From domain is the platform sender domain or a subdomain of it.
 *
 * Returns "" when the message is trusted, else the reason it is not.
 */
export function mailVerdict(text, senderDomain) {
  const { headers, count } = splitHeaders(text);
  const want = (senderDomain ?? "").toLowerCase();
  if ((count.from ?? 0) !== 1) return `the message has ${count.from ?? 0} From headers, want exactly one`;
  const from = (addresses(headers.from)[0]?.Address ?? "").toLowerCase();
  const fromDomain = from.split("@")[1] ?? "";
  if (!want) return "no platform sender domain";
  if (!(fromDomain === want || fromDomain.endsWith(`.${want}`))) return `From ${from || "(none)"} is not on ${want}`;
  const ar = (headers["authentication-results"] ?? "").toLowerCase();
  if (!ar.startsWith("amazonses.com")) return "no Authentication-Results header from amazonses.com";
  if (!/\bspf=pass\b/.test(ar)) return "SES did not see spf=pass";
  const aligned = [...ar.matchAll(/\bdkim=pass\b([^;]*)/g)].some((m) => {
    const d = (m[1].match(/header\.d=([a-z0-9.-]+)/) ?? m[1].match(/header\.i=[^@\s]*@([a-z0-9.-]+)/) ?? [])[1] ?? "";
    return d.split(".").length >= 2 && (fromDomain === d || fromDomain.endsWith(`.${d}`));
  });
  if (!aligned) return `SES saw no dkim=pass aligned with ${fromDomain}`;
  return "";
}

export function trustedPlatformMail(text, senderDomain) {
  return mailVerdict(text, senderDomain) === "";
}

export function summary(id, text, created) {
  const { headers } = splitHeaders(text);
  return {
    ID: id,
    Subject: decodeWords(headers.subject),
    Created: created ?? headers.date ?? "",
    To: addresses(headers.to),
  };
}

function decodePart(headers, body) {
  const enc = (headers["content-transfer-encoding"] ?? "").toLowerCase();
  if (enc === "base64") return Buffer.from(body.replace(/\s+/g, ""), "base64").toString("utf8");
  if (enc === "quoted-printable") {
    const bytes = body.replace(/=\r?\n/g, "").replace(/=([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
    return Buffer.from(bytes, "latin1").toString("utf8");
  }
  return body;
}

/** The decoded text/plain and text/html parts of a raw message, joined. */
export function decodeBody(text) {
  const { headers, body } = splitHeaders(text);
  const type = headers["content-type"] ?? "text/plain";
  const b = type.match(/boundary="?([^";]+)"?/i);
  if (/^multipart\//i.test(type) && b) {
    return body.split(`--${b[1]}`).slice(1)
      .filter((p) => !p.startsWith("--"))
      .map((p) => decodeBody(p.replace(/^\r?\n/, "")))
      .filter(Boolean)
      .join("\n");
  }
  if (/^text\/(plain|html)/i.test(type)) return decodePart(headers, body);
  return "";
}
