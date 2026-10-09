import { apiError, sessionClient } from '@/lib/server';
export async function GET() {
  try {
    const { client } = await sessionClient();
    const { data, error } = await client.rpc('tracker_backup');
    if (error) throw error;
    return new Response(JSON.stringify(data, null, 2), { headers: { 'Content-Type': 'application/json', 'Content-Disposition': 'attachment; filename="salary-tracker-backup.json"', 'Cache-Control': 'no-store' } });
  } catch (error) { return apiError(error); }
}
