/**
 * contact-sales — turn a form submission into an email to the sales inbox.
 *
 * Replaces the dashboard's app/api/contact-sales/route.ts, which cannot run:
 * it needs a Next server, and the marketing site is files on object storage
 * (ADR-0077).
 *
 * WHAT IS DELIBERATELY ABSENT: every line of CORS. The original carried an
 * origin allowlist, an OPTIONS preflight handler, a `Vary: Origin` header and
 * a 403-on-unknown-origin branch — all of it because the form and the endpoint
 * sat on different hosts. This Lambda is a second ORIGIN on the same
 * CloudFront distribution that serves the form, so the browser sees one
 * origin and none of that apparatus is needed. It is deleted, not ported.
 *
 * Delivery is SNS, not SES. SNS needs no verified domain identity and no
 * production-access request, and it keeps lead mail off the reputation of the
 * sender that carries signup verification (launch blocker 2). The trade-off,
 * accepted: SNS mail is plain text from an Amazon address, so the lead's own
 * address is in the body and reply-to does not work.
 *
 * Rate limiting is the account's Lambda concurrency ceiling, not a WAF rule.
 * A WAF rate rule costs ~$6/month against a ~$2/month site, for a form nobody
 * has submitted yet.
 */
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';

const sns = new SNSClient({});
const TOPIC_ARN = process.env.LEAD_TOPIC_ARN;

/** Mirrors the zod schema the form validates against, field for field. */
const ENUMS = {
  companySize: ['1-50', '51-200', '201-1000', '1000+'],
  deployment: ['cloud', 'self-hosted', 'hybrid'],
  timeline: ['asap', '1-3-months', '3-6-months', 'evaluating'],
};

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function reply(statusCode, body) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    body: JSON.stringify(body),
  };
}

/**
 * Validate a submission.
 *
 * Returns the cleaned lead, or a list of field errors. Length caps match the
 * form's, so a payload the browser accepted is never rejected here, and a
 * payload that skipped the browser cannot be unbounded.
 */
function validate(input) {
  const errors = [];
  const str = (key, max, required = true) => {
    const v = typeof input[key] === 'string' ? input[key].trim() : '';
    if (required && v.length === 0) errors.push(`${key} is required`);
    if (v.length > max) errors.push(`${key} must be at most ${max} characters`);
    return v.slice(0, max);
  };

  const lead = {
    name: str('name', 100),
    email: str('email', 254),
    company: str('company', 100),
    useCase: str('useCase', 1000, false),
  };

  if (lead.email && !EMAIL_RE.test(lead.email)) errors.push('email must be a valid address');

  for (const [key, allowed] of Object.entries(ENUMS)) {
    if (!allowed.includes(input[key])) {
      errors.push(`${key} must be one of ${allowed.join(', ')}`);
    } else {
      lead[key] = input[key];
    }
  }

  return { lead, errors };
}

function render(lead) {
  return [
    `Name:        ${lead.name}`,
    `Email:       ${lead.email}`,
    `Company:     ${lead.company}`,
    `Size:        ${lead.companySize}`,
    `Deployment:  ${lead.deployment}`,
    `Timeline:    ${lead.timeline}`,
    '',
    'Use case:',
    lead.useCase || '(not provided)',
    '',
    '--',
    'Reply to the address above; this message is sent by SNS and cannot be replied to directly.',
  ].join('\n');
}

export async function handler(event) {
  const method = event?.requestContext?.http?.method ?? 'POST';
  if (method !== 'POST') return reply(405, { error: 'Method not allowed' });

  let input;
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body ?? '', 'base64').toString('utf8')
      : (event.body ?? '');
    input = JSON.parse(raw);
  } catch {
    return reply(400, { error: 'Malformed request' });
  }

  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    return reply(400, { error: 'Malformed request' });
  }

  const { lead, errors } = validate(input);
  if (errors.length > 0) return reply(400, { error: errors[0], errors });

  try {
    await sns.send(
      new PublishCommand({
        TopicArn: TOPIC_ARN,
        Subject: `[Sales] ${lead.company} (${lead.companySize}), ${lead.timeline}`.slice(0, 100),
        Message: render(lead),
      }),
    );
  } catch (err) {
    // Log without the submitter's identity: the message body already went
    // nowhere, and a failed lead is an operational event, not a record to keep.
    console.error(JSON.stringify({ event: 'contact_sales.publish_failed', reason: err?.name }));
    return reply(502, { error: 'Could not deliver your message. Please email sales@zeroroot.ai.' });
  }

  // Structured line so a lead is greppable even if the mail is lost. Company
  // and shape only — the address lives in the delivered message, not the logs.
  console.log(
    JSON.stringify({
      event: 'contact_sales.submitted',
      company: lead.company,
      company_size: lead.companySize,
      deployment: lead.deployment,
      timeline: lead.timeline,
    }),
  );

  return reply(200, { success: true });
}
