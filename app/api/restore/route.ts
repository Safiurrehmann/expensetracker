import { apiError, sessionClient, sameOrigin } from '@/lib/server';
export async function POST(request: Request) {
  try {
    sameOrigin(request);
    const { client } = await sessionClient();
    const body = await request.json();
    const { data, error } = await client.rpc('tracker_restore', { p_backup: body });
    if (error) throw error;
    return Response.json(data);
  } catch (error) { return apiError(error); }
}
