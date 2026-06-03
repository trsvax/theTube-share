/**
 * tube-client.js — browser client for the tube.
 *
 * Fire-and-forget: data in the URL, 202, done.
 * Ticket (async): POST to tube, get presigned URLs, upload files, poll result.
 * Ticket (sync): POST to tube, get result inline.
 *
 * Auth: Cognito JWT (from cookie/session) or anonymous token (for public captures).
 * No secrets in the browser. The JWT is enough — edge checks presence, Lambda checks validity.
 *
 * Usage:
 *   import { tube } from '/js/tube-client.js';
 *
 *   // Fire-and-forget (contact form, reaction, bookmark)
 *   await tube.capture('contact', { name: 'Alice', message: 'Hello' });
 *
 *   // Sync request (comment submission — returns moderation result)
 *   const result = await tube.request('comments/add', { post: 'the-mvp', body: 'Great post' });
 *
 *   // Async upload (file upload with polling)
 *   const result = await tube.upload('share/add', files, { caption: 'batch from temple' });
 */

const TUBE_URL = '/tube';

/**
 * Get the current auth token.
 * Cognito: read from cookie (HttpOnly, set by auth-callback Lambda@Edge).
 * Anonymous: use a pre-set token for public captures.
 *
 * @returns {string | null}
 */
function getToken() {
  // Cognito JWT is in an HttpOnly cookie — browser sends it automatically.
  // For API calls where we need the header, check if we have a session token.
  const meta = document.querySelector('meta[name="tube-token"]');
  if (meta) return meta.getAttribute('content');

  // Fallback: anonymous capture token (set by the site at build time or first load)
  return window.__TUBE_TOKEN || null;
}

/**
 * Fire-and-forget capture. Data in the URL. 202 Noted.
 * No ticket, no polling. For forms, reactions, bookmarks.
 *
 * @param {string} path — tube path (e.g. 'contact', 'share/add', 'react')
 * @param {Record<string, string>} params — key-value pairs for the query string
 * @returns {Promise<boolean>} — true if 202
 */
async function capture(path, params = {}) {
  const token = getToken();
  const qs = new URLSearchParams(params);

  // Token in query string for fire-and-forget (CF logs it, processor verifies later)
  if (token) qs.set('auth', token);

  const url = `${TUBE_URL}/${path}?${qs}`;

  const response = await fetch(url, { method: 'POST', credentials: 'include' });
  return response.status === 202;
}

/**
 * Sync request. POST to tube, get result inline (200).
 * For operations that need an immediate answer (comment moderation, validation).
 *
 * @param {string} path — tube path (e.g. 'comments/add')
 * @param {Record<string, unknown>} body — request body (JSON)
 * @returns {Promise<unknown>} — parsed result
 */
async function request(path, body = {}) {
  const token = getToken();
  const url = `${TUBE_URL}/${path}`;

  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    credentials: 'include',
  });

  if (response.status === 200) {
    return response.json();
  }

  if (response.status === 403) {
    throw new TubeError('Not authorized', response.status);
  }

  throw new TubeError(`Unexpected ${response.status}`, response.status);
}

/**
 * Async upload. Get a ticket, upload files to presigned URL, poll for result.
 * One ticket, N files. The locker is the unit.
 *
 * @param {string} path — tube path (e.g. 'share/add')
 * @param {FileList | File[]} files — files to upload
 * @param {Record<string, string>} [meta] — metadata (caption, date, etc.)
 * @param {{ timeout?: number, onProgress?: (n: number, total: number) => void }} [opts]
 * @returns {Promise<unknown>} — parsed result from processor
 */
async function upload(path, files, meta = {}, opts = {}) {
  const token = getToken();
  const timeout = opts.timeout || 30_000;
  const url = `${TUBE_URL}/${path}`;

  // Request a ticket
  const qs = new URLSearchParams({
    ...meta,
    count: String(files.length),
    file: files[0]?.name || 'upload',
    type: meta.type || 'image',
    date: meta.date || new Date().toISOString().slice(0, 10),
  });

  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  const ticketResponse = await fetch(`${url}?${qs}`, {
    method: 'POST',
    headers,
    credentials: 'include',
  });

  if (ticketResponse.status !== 202) {
    throw new TubeError('Ticket request failed', ticketResponse.status);
  }

  const ticket = await ticketResponse.json();
  const { write, result: resultUrl } = ticket;

  if (!write) {
    throw new TubeError('No upload URL in ticket', 202);
  }

  // Upload each file using the presigned POST policy
  let uploaded = 0;
  for (const file of files) {
    const formData = new FormData();

    // Add all policy fields first (order matters for S3)
    for (const [k, v] of Object.entries(write.fields)) {
      const value = k === 'key' ? v.replace('${filename}', file.name) : v;
      formData.append(k, value);
    }
    formData.append('Content-Type', file.type || 'application/octet-stream');
    formData.append('file', file);

    const uploadResponse = await fetch(write.url, { method: 'POST', body: formData });

    if (uploadResponse.ok) {
      uploaded++;
      opts.onProgress?.(uploaded, files.length);
    }
  }

  if (uploaded === 0) {
    throw new TubeError('All uploads failed', 0);
  }

  // Poll for result
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    await sleep(1000);

    const check = await fetch(resultUrl);
    if (check.status === 200) {
      return check.json();
    }
    if (check.status !== 403 && check.status !== 404) {
      throw new TubeError(`Unexpected ${check.status} polling result`, check.status);
    }
  }

  // Timeout — return the result URL so caller can try later
  return { pending: true, resultUrl, uploaded, total: files.length };
}

// --- Error ---

class TubeError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'TubeError';
    this.status = status;
  }
}

// --- Helpers ---

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// --- Export ---

export const tube = { capture, request, upload, TubeError };
