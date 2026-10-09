import { createClient } from '@supabase/supabase-js';
import { cookies } from 'next/headers';
export const cookieName = 'tracker_session';
const refreshName = 'tracker_refresh';
export function config() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_ANON_KEY;
  const ownerEmail = process.env.TRACKER_OWNER_EMAIL?.trim().toLowerCase();
  if (!url || !key || !ownerEmail) throw new Error('Supabase is not configured. Add SUPABASE_URL, SUPABASE_ANON_KEY, and TRACKER_OWNER_EMAIL to .env.local.');
  return { url, key, ownerEmail };
}
function clientFor(token?: string) {
  const { url, key } = config();
  return createClient(url, key, { auth: { persistSession: false }, ...(token ? { global: { headers: { Authorization: `Bearer ${token}` } } } : {}) });
}
export async function saveSession(accessToken: string, refreshToken: string, expiresIn: number) {
  const jar = await cookies();
  const options = { httpOnly: true, secure: process.env.NODE_ENV === 'production', sameSite: 'lax' as const, path: '/' };
  jar.set(cookieName, accessToken, { ...options, maxAge: Math.max(60, expiresIn - 60) });
  jar.set(refreshName, refreshToken, { ...options, maxAge: 60 * 60 * 24 * 30 });
}
export async function clearSession() {
  const jar = await cookies();
  jar.delete(cookieName);
  jar.delete(refreshName);
}
export async function sessionClient() {
  const jar = await cookies();
  let token = jar.get(cookieName)?.value;
  const refresh = jar.get(refreshName)?.value;
  if (!token && refresh) {
    const { data, error } = await clientFor().auth.refreshSession({ refresh_token: refresh });
    if (error || !data.session) throw new Error('Unauthorized');
    token = data.session.access_token;
    await saveSession(token, data.session.refresh_token, data.session.expires_in);
  }
  if (!token) throw new Error('Unauthorized');
  const client = clientFor(token);
  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user || data.user.email?.toLowerCase() !== config().ownerEmail) throw new Error('Unauthorized');
  return { client, user: data.user };
}
export function sameOrigin(request: Request) {
  const origin = request.headers.get('origin');
  const target = new URL(request.url);
  if (origin && new URL(origin).origin !== target.origin) throw new Error('Cross-origin request blocked');
}
export function apiError(error: unknown) {
  const message = error instanceof Error ? error.message : 'Request failed';
  return Response.json({ error: message }, { status: message === 'Unauthorized' ? 401 : 400 });
}
