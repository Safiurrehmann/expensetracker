import test from 'node:test';
import assert from 'node:assert/strict';
import { authErrorMessage } from '../lib/auth-errors.ts';
test('unconfirmed owner gets a confirmation instruction',()=>{
 assert.match(authErrorMessage({code:'email_not_confirmed',status:400}),/confirm your email/i);
});
test('rate-limited owner gets a wait instruction',()=>{
 assert.match(authErrorMessage({code:'over_email_send_rate_limit',status:429}),/wait/i);
});
test('other failures do not expose provider details',()=>{
 assert.equal(authErrorMessage({code:'invalid_credentials',status:400}),'Invalid email or password.');
});
