import { createClient } from '@supabase/supabase-js';
import { config, saveSession, clearSession, apiError, sameOrigin } from '@/lib/server';
export async function POST(request: Request) {
  try {
    sameOrigin(request);
    const { email, password, mode } = await request.json();
    if (typeof email !== 'string' || typeof password !== 'string' || password.length < 8) throw new Error('Enter a valid email and a password of at least 8 characters.');
    const { url, key, ownerEmail } = config();
    if (email.trim().toLowerCase() !== ownerEmail) throw new Error('This email is not the configured owner.');
    const client = createClient(url, key, { auth: { persistSession: false } });
    if (mode === 'signup') {
      const { data, error } = await client.auth.signUp({ email: ownerEmail, password });
      if (error) throw new Error(error.message);
      if (data.session) {
        await saveSession(data.session.access_token, data.session.refresh_token, data.session.expires_in);
        return Response.json({ ok: true, pendingConfirmation: false });
      }
      return Response.json({ ok: true, pendingConfirmation: true });
    }
    const { data, error } = await client.auth.signInWithPassword({ email: ownerEmail, password });
    if (error || !data.session || data.user?.email?.toLowerCase() !== ownerEmail) throw new Error('Invalid email or password.');
    await saveSession(data.session.access_token, data.session.refresh_token, data.session.expires_in);
    return Response.json({ ok: true });
  } catch (error) { return apiError(error); }
}
export async function DELETE(request: Request) { try { sameOrigin(request); await clearSession(); return Response.json({ ok: true }); } catch (error) { return apiError(error); } }
