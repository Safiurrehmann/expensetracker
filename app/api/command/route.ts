import { apiError, sessionClient, sameOrigin } from '@/lib/server';
export async function POST(request: Request) {
  try {
    sameOrigin(request);
    const { client } = await sessionClient();
    const body = await request.json();
    if (!body || typeof body !== 'object' || typeof body.type !== 'string') throw new Error('Invalid command.');
    const { data, error } = await client.rpc('tracker_command', { p_command: body });
    if (error) throw error;
    return Response.json(data, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) { return apiError(error); }
}
