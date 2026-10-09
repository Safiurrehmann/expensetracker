/** PKR values are stored as integer paise. Decimal input never passes through binary float arithmetic. */
export function parsePkr(input: string): number {
  const clean = input.replace(/,/g, '').trim();
  if (!/^\d+(?:\.\d{1,2})?$/.test(clean)) throw new Error('Enter a non-negative PKR amount with up to two decimal places.');
  const [rupees, paise = ''] = clean.split('.');
  const value = BigInt(rupees) * 100n + BigInt(paise.padEnd(2, '0'));
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Amount is too large.');
  return Number(value);
}
export function formatPkr(paise: number): string {
  const sign = paise < 0 ? '−' : '';
  const absolute = Math.abs(paise);
  return `${sign}PKR ${new Intl.NumberFormat('en-PK').format(Math.floor(absolute / 100))}${absolute % 100 ? `.${String(absolute % 100).padStart(2, '0')}` : ''}`;
}
export function previewSalary(income: number, rows: { amount: number }[]) {
  const committed = rows.reduce((sum, row) => sum + row.amount, 0);
  return { committed, contribution: income - committed, draw: Math.max(0, committed - income) };
}
