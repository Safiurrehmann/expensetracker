import { apiError, sessionClient } from '@/lib/server';
export async function GET() {
  try {
    const { client, user } = await sessionClient();
    const { data, error } = await client.rpc('tracker_state');
    if (error) throw error;
    return Response.json({ ...data, email: user.email }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) { return apiError(error); }
}
