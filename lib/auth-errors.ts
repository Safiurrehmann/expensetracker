export function authErrorMessage(error: { code?: string; status?: number }, action: 'login' | 'signup' | 'resend' = 'login'): string {
  if (error.code === 'email_not_confirmed') return 'Confirm your email using the link we sent, then sign in.';
  if (error.status === 429 || error.code?.includes('rate_limit')) return 'Too many attempts. Wait before trying again or resending the email.';
  if (action === 'signup') return 'Could not create the account. Check the password requirements and try again.';
  if (action === 'resend') return 'Could not resend the confirmation email. Try again later.';
  return 'Invalid email or password.';
}
