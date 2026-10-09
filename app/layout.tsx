import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'Stillmine — Salary & Savings', description: 'Know what is still yours to save.' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="en"><body>{children}</body></html>; }
