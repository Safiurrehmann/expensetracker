-- Apply in the Supabase SQL editor. All writes go through authenticated, transactional RPCs.
create extension if not exists pgcrypto;
create table public.tracker_owners (owner_id uuid primary key references auth.users(id) on delete cascade, version bigint not null default 0, salary_default bigint not null default 9000000, opening_date date, created_at timestamptz not null default now());
create table public.tracker_accounts (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, name text not null, active boolean not null default true, confirmed_at date, estimated boolean not null default true);
create table public.tracker_funds (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, name text not null, active boolean not null default true, rule_amount bigint, suggested_account uuid references public.tracker_accounts(id), created_at timestamptz not null default now());
create table public.tracker_cycles (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, period text not null, status text not null check(status in ('draft','approved','closed')), receipt_amount bigint not null default 0, receipt_date date, receiving_account uuid references public.tracker_accounts(id), income_source text, approved_at timestamptz, version bigint not null default 0, unique(owner_id,period));
create table public.tracker_allocations (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, cycle_id uuid not null references public.tracker_cycles(id) on delete cascade, fund_id uuid references public.tracker_funds(id), label text not null, amount bigint not null check(amount>=0), one_time boolean not null default false, suggested_account uuid references public.tracker_accounts(id), unique(cycle_id,fund_id));
create table public.tracker_loans (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, borrower text not null, principal bigint not null check(principal>0), repaid bigint not null default 0, waived bigint not null default 0, source_fund uuid references public.tracker_funds(id), due_date date, created_at timestamptz not null default now(), check(repaid>=0 and waived>=0 and repaid+waived<=principal));
create table public.tracker_events (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, batch_id uuid not null, kind text not null, amount bigint not null, effective_date date not null, posted_at timestamptz not null default now(), note text, cycle_id uuid references public.tracker_cycles(id), loan_id uuid references public.tracker_loans(id), reverses uuid references public.tracker_events(id), related_event uuid references public.tracker_events(id), idempotency_key text, unique(owner_id,idempotency_key));
create table public.tracker_legs (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, event_id uuid not null references public.tracker_events(id) on delete cascade, account_id uuid references public.tracker_accounts(id), fund_id uuid references public.tracker_funds(id), cash_delta bigint not null default 0, savings_delta bigint not null default 0, fund_delta bigint not null default 0, unassigned_delta bigint not null default 0, loan_delta bigint not null default 0, check (cash_delta=savings_delta+fund_delta+unassigned_delta));
create table public.tracker_audit (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, entity_type text not null, entity_id uuid, before_value jsonb, after_value jsonb, reason text, created_at timestamptz not null default now());
create table public.tracker_reconciliations (id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.tracker_owners(owner_id) on delete cascade, account_id uuid not null references public.tracker_accounts(id), as_of date not null, observed bigint not null, recorded_before bigint not null, adjustment_event uuid references public.tracker_events(id), status text not null default 'confirmed', created_at timestamptz not null default now());
create index on public.tracker_events(owner_id,effective_date desc,posted_at desc);
create index on public.tracker_legs(owner_id,account_id);
create index on public.tracker_legs(owner_id,fund_id);
create index on public.tracker_allocations(owner_id,cycle_id);
create index on public.tracker_audit(owner_id,created_at desc);
alter table public.tracker_owners enable row level security;
alter table public.tracker_accounts enable row level security;
alter table public.tracker_funds enable row level security;
alter table public.tracker_cycles enable row level security;
alter table public.tracker_allocations enable row level security;
alter table public.tracker_loans enable row level security;
alter table public.tracker_events enable row level security;
alter table public.tracker_legs enable row level security;
alter table public.tracker_audit enable row level security;
alter table public.tracker_reconciliations enable row level security;
-- No direct client table grants. RPCs use auth.uid() and own every row they touch.
revoke all on public.tracker_owners, public.tracker_accounts, public.tracker_funds, public.tracker_cycles, public.tracker_allocations, public.tracker_loans, public.tracker_events, public.tracker_legs, public.tracker_audit, public.tracker_reconciliations from anon, authenticated;
create or replace function public.tracker_balances(p_owner uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('cash',coalesce(sum(cash_delta),0),'savings',coalesce(sum(savings_delta),0),'committed',coalesce(sum(fund_delta),0),'unassigned',coalesce(sum(unassigned_delta),0),'loans',coalesce(sum(loan_delta),0)) from public.tracker_legs where owner_id=p_owner;
$$;
create or replace function public.tracker_state() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o uuid:=auth.uid(); result jsonb; begin
 if o is null then raise exception 'Unauthorized'; end if;
 select jsonb_build_object(
 'owner',(select to_jsonb(x) from public.tracker_owners x where x.owner_id=o),
 'balances',public.tracker_balances(o),
 'accounts',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('balance',coalesce((select sum(l.cash_delta) from public.tracker_legs l where l.owner_id=o and l.account_id=a.id),0)) order by a.name) from public.tracker_accounts a where a.owner_id=o),'[]'::jsonb),
 'funds',coalesce((select jsonb_agg(to_jsonb(f)||jsonb_build_object('balance',coalesce((select sum(l.fund_delta) from public.tracker_legs l where l.owner_id=o and l.fund_id=f.id),0)) order by f.created_at) from public.tracker_funds f where f.owner_id=o),'[]'::jsonb),
 'cycles',coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('allocations',coalesce((select jsonb_agg(to_jsonb(a) order by a.label) from public.tracker_allocations a where a.cycle_id=c.id),'[]'::jsonb)) order by c.period desc) from public.tracker_cycles c where c.owner_id=o),'[]'::jsonb),
 'loans',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from public.tracker_loans x where x.owner_id=o),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('legs',coalesce((select jsonb_agg(to_jsonb(l)) from public.tracker_legs l where l.event_id=e.id),'[]'::jsonb)) order by e.effective_date desc,e.posted_at desc) from (select * from public.tracker_events where owner_id=o order by effective_date desc,posted_at desc limit 200) e),'[]'::jsonb),
 'audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (select * from public.tracker_audit where owner_id=o order by created_at desc limit 100) a),'[]'::jsonb),
 'reconciliations',coalesce((select jsonb_agg(to_jsonb(r) order by r.as_of desc) from public.tracker_reconciliations r where r.owner_id=o),'[]'::jsonb)
 ) into result;
 return result;
end $$;
create or replace function public.tracker_post(p_owner uuid,p_kind text,p_amount bigint,p_date date,p_note text,p_legs jsonb,p_cycle uuid default null,p_loan uuid default null,p_reverses uuid default null,p_key text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare event_id uuid; item jsonb; acct uuid; fund uuid; c bigint; s bigint; f bigint; u bigint; l bigint; begin
 if p_amount<0 then raise exception 'Negative amount'; end if;
 if p_legs is null or jsonb_typeof(p_legs)<>'array' or jsonb_array_length(p_legs)=0 then raise exception 'Event needs legs'; end if;
 insert into public.tracker_events(owner_id,batch_id,kind,amount,effective_date,note,cycle_id,loan_id,reverses,idempotency_key) values(p_owner,gen_random_uuid(),p_kind,p_amount,p_date,p_note,p_cycle,p_loan,p_reverses,p_key) returning id into event_id;
 for item in select * from jsonb_array_elements(p_legs) loop
  acct:=nullif(item->>'account','')::uuid; fund:=nullif(item->>'fund','')::uuid;
  c:=coalesce((item->>'cash')::bigint,0); s:=coalesce((item->>'savings')::bigint,0); f:=coalesce((item->>'committed')::bigint,0); u:=coalesce((item->>'unassigned')::bigint,0); l:=coalesce((item->>'loan')::bigint,0);
  if c<>s+f+u then raise exception 'Cash-purpose invariant failed'; end if;
  if acct is not null and not exists(select 1 from public.tracker_accounts where id=acct and owner_id=p_owner) then raise exception 'Invalid account'; end if;
  if fund is not null and not exists(select 1 from public.tracker_funds where id=fund and owner_id=p_owner) then raise exception 'Invalid fund'; end if;
  if c<>0 and acct is null then raise exception 'Cash leg needs account'; end if;
  if f<>0 and fund is null then raise exception 'Commitment leg needs fund'; end if;
  insert into public.tracker_legs(owner_id,event_id,account_id,fund_id,cash_delta,savings_delta,fund_delta,unassigned_delta,loan_delta) values(p_owner,event_id,acct,fund,c,s,f,u,l);
 end loop;
 return event_id;
end $$;
revoke all on function public.tracker_post(uuid,text,bigint,date,text,jsonb,uuid,uuid,uuid,text) from public, anon, authenticated;
create or replace function public.tracker_command(p_command jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); kind text:=p_command->>'type'; ver bigint; b jsonb; amt bigint; d date; acct uuid; target uuid; fund uuid; cycle uuid; loan uuid; ev uuid; row_item jsonb; legs jsonb; old_amount bigint; paid bigint; new_amount bigint; receipt bigint; total bigint; borrow text; current_balance bigint; note text:=nullif(p_command->>'note',''); key text:=nullif(p_command->>'key',''); before_state jsonb; original record; new_ev uuid; command_started timestamptz:=now(); covered bigint; extra bigint; portion bigint; leg_index int; leg_count int; source_leg record; consumed bigint; begin
 if o is null then raise exception 'Unauthorized'; end if;
 if kind='setup' then
  if exists(select 1 from public.tracker_owners where owner_id=o) then raise exception 'Opening setup already completed'; end if;
  d:=(p_command->>'date')::date;
  if d is null then raise exception 'Choose opening date'; end if;
  insert into public.tracker_owners(owner_id,opening_date) values(o,d);
  for row_item in select * from jsonb_array_elements(p_command->'accounts') loop
   amt:=(row_item->>'amount')::bigint; if amt<0 then raise exception 'Negative opening balance'; end if;
   insert into public.tracker_accounts(owner_id,name,confirmed_at,estimated) values(o,row_item->>'name',d,coalesce((row_item->>'estimated')::boolean,true)) returning id into acct;
   perform public.tracker_post(o,'opening_cash',amt,d,'Opening balance',jsonb_build_array(jsonb_build_object('account',acct,'cash',amt,'unassigned',amt)));
  end loop;
  for row_item in select * from jsonb_array_elements(p_command->'funds') loop
   amt:=(row_item->>'amount')::bigint; if amt<0 then raise exception 'Negative opening fund'; end if;
   insert into public.tracker_funds(owner_id,name,rule_amount) values(o,row_item->>'name',coalesce((row_item->>'ruleAmount')::bigint,amt)) returning id into fund;
   if amt>0 then perform public.tracker_post(o,'opening_classification',amt,d,'Opening purpose',jsonb_build_array(jsonb_build_object('fund',fund,'committed',amt,'unassigned',-amt))); end if;
  end loop;
  amt:=coalesce((p_command->>'savings')::bigint,0); if amt<0 then raise exception 'Negative opening savings'; end if;
  if amt>0 then perform public.tracker_post(o,'opening_classification',amt,d,'Opening savings',jsonb_build_array(jsonb_build_object('savings',amt,'unassigned',-amt))); end if;
  update public.tracker_owners set salary_default=coalesce((p_command->>'salaryDefault')::bigint,9000000) where owner_id=o;
 else
  select version into ver from public.tracker_owners where owner_id=o for update;
  if not found then raise exception 'Complete opening setup first'; end if;
  if (p_command->>'version')::bigint is distinct from ver then raise exception 'Data changed in another tab. Reload and preview again'; end if;
  if key is not null and exists(select 1 from public.tracker_events where owner_id=o and idempotency_key=key) then return public.tracker_state(); end if;
  d:=coalesce((p_command->>'date')::date,(now() at time zone 'Asia/Karachi')::date);
  amt:=coalesce((p_command->>'amount')::bigint,0);
  acct:=nullif(p_command->>'account','')::uuid; fund:=nullif(p_command->>'fund','')::uuid; cycle:=nullif(p_command->>'cycle','')::uuid; loan:=nullif(p_command->>'loan','')::uuid;
  if acct is not null and not exists(select 1 from public.tracker_accounts where id=acct and owner_id=o and active) then raise exception 'Invalid account'; end if;
  if fund is not null and not exists(select 1 from public.tracker_funds where id=fund and owner_id=o and active) then raise exception 'Invalid fund'; end if;
  if cycle is not null and not exists(select 1 from public.tracker_cycles where id=cycle and owner_id=o) then raise exception 'Invalid cycle'; end if;
  if loan is not null and not exists(select 1 from public.tracker_loans where id=loan and owner_id=o) then raise exception 'Invalid loan'; end if;
  if kind='save_draft' then
   if not (p_command->>'period' ~ '^\d{4}-\d{2}$') then raise exception 'Invalid salary period'; end if;
   if amt<0 or acct is null then raise exception 'Enter salary and receiving account'; end if;
   select id into cycle from public.tracker_cycles where owner_id=o and period=p_command->>'period';
   if cycle is not null and (select status from public.tracker_cycles where id=cycle)<>'draft' then raise exception 'Cycle is already approved'; end if;
   if cycle is null then insert into public.tracker_cycles(owner_id,period,status) values(o,p_command->>'period','draft') returning id into cycle; end if;
   update public.tracker_cycles set receipt_amount=amt,receipt_date=d,receiving_account=acct,income_source=nullif(p_command->>'source',''),version=version+1 where id=cycle;
   delete from public.tracker_allocations where cycle_id=cycle;
   for row_item in select * from jsonb_array_elements(p_command->'rows') loop
    fund:=nullif(row_item->>'fund','')::uuid; new_amount:=(row_item->>'amount')::bigint;
    if new_amount<0 then raise exception 'Negative allocation'; end if;
    if fund is not null and not exists(select 1 from public.tracker_funds where id=fund and owner_id=o) then raise exception 'Invalid fund'; end if;
    if fund is null then insert into public.tracker_funds(owner_id,name,rule_amount) values(o,row_item->>'label',case when coalesce((row_item->>'oneTime')::boolean,false) then null else new_amount end) returning id into fund; end if;
    insert into public.tracker_allocations(owner_id,cycle_id,fund_id,label,amount,one_time,suggested_account) values(o,cycle,fund,row_item->>'label',new_amount,coalesce((row_item->>'oneTime')::boolean,false),nullif(row_item->>'account','')::uuid);
   end loop;
  elsif kind='approve_salary' then
   if cycle is null then raise exception 'Select a draft'; end if;
   select receipt_amount,receiving_account,receipt_date into receipt,acct,d from public.tracker_cycles where id=cycle and status='draft' for update;
   if not found or receipt<=0 then raise exception 'Salary receipt must be positive'; end if;
   select coalesce(sum(amount),0) into total from public.tracker_allocations where cycle_id=cycle;
   b:=public.tracker_balances(o);
   if total>receipt and (p_command->>'useSavings')::boolean is distinct from true then raise exception 'Allocations exceed salary. Confirm use of existing savings'; end if;
   if total-receipt>(b->>'savings')::bigint then raise exception 'Not enough protected savings'; end if;
   perform public.tracker_post(o,'salary',receipt,d,'Salary receipt',jsonb_build_array(jsonb_build_object('account',acct,'cash',receipt,'savings',receipt)),cycle,null,null,key);
   for row_item in select to_jsonb(a) from public.tracker_allocations a where a.cycle_id=cycle loop
    if (row_item->>'amount')::bigint>0 then
     perform public.tracker_post(o,'allocation',(row_item->>'amount')::bigint,d,row_item->>'label',jsonb_build_array(jsonb_build_object('fund',row_item->>'fund_id','savings',-((row_item->>'amount')::bigint),'committed',(row_item->>'amount')::bigint)),cycle);
    end if;
   end loop;
   update public.tracker_cycles set status='approved',approved_at=now(),version=version+1 where id=cycle;
  elsif kind='edit_allocation' then
   select a.amount into old_amount from public.tracker_allocations a join public.tracker_cycles c on c.id=a.cycle_id where a.cycle_id=cycle and a.fund_id=fund and c.owner_id=o and c.status='approved' for update of a;
   if not found then raise exception 'Approved allocation not found'; end if;
   new_amount:=amt; if new_amount<0 then raise exception 'Negative allocation'; end if;
   select coalesce(sum(fund_delta),0) into current_balance from public.tracker_legs where owner_id=o and fund_id=fund;
   if old_amount-new_amount>current_balance then raise exception 'Already consumed funds cannot be released'; end if;
   select greatest(0,-coalesce(sum(l.fund_delta),0)) into consumed from public.tracker_legs l join public.tracker_events e on e.id=l.event_id where l.owner_id=o and l.fund_id=fund and e.posted_at >= (select approved_at from public.tracker_cycles where id=cycle) and e.kind in ('spend','settle','reconciliation','refund','reversal');
   if new_amount<consumed then raise exception 'Approved amount cannot be lower than consumption since approval'; end if;
   b:=public.tracker_balances(o);
   if new_amount>old_amount and new_amount-old_amount>(b->>'savings')::bigint then raise exception 'Not enough savings'; end if;
   before_state:=jsonb_build_object('amount',old_amount);
   update public.tracker_allocations set amount=new_amount where cycle_id=cycle and fund_id=fund;
   perform public.tracker_post(o,'allocation_revision',abs(new_amount-old_amount),d,'Allocation revised',jsonb_build_array(jsonb_build_object('fund',fund,'savings',old_amount-new_amount,'committed',new_amount-old_amount)),cycle,null,null,key);
   insert into public.tracker_audit(owner_id,entity_type,entity_id,before_value,after_value,reason) values(o,'allocation',fund,before_state,jsonb_build_object('amount',new_amount),note);
   if (p_command->>'future')::boolean is true then update public.tracker_funds set rule_amount=new_amount where id=fund; end if;
  elsif kind='spend' or kind='lend' or kind='settle' then
   if amt<=0 or acct is null then raise exception 'Enter a positive amount and account'; end if;
   if exists(select 1 from public.tracker_reconciliations r where r.owner_id=o and r.account_id=acct and r.as_of>=d and r.adjustment_event is not null and r.status='confirmed') then raise exception 'This date is covered by a reconciliation adjustment; review it before adding an expense'; end if;
   select coalesce(sum(cash_delta),0) into current_balance from public.tracker_legs where owner_id=o and account_id=acct;
   if current_balance<amt then raise exception 'Not enough recorded cash in this account'; end if;
   b:=public.tracker_balances(o);
   if fund is not null then
    select coalesce(sum(fund_delta),0) into current_balance from public.tracker_legs where owner_id=o and fund_id=fund;
    covered:=least(amt,current_balance); extra:=amt-covered;
    if extra>0 and kind='lend' then raise exception 'Loan funding split is not available'; end if;
    if extra>0 and (p_command->>'useSavings')::boolean is distinct from true then raise exception 'Fund is short. Confirm the extra savings deduction'; end if;
    if extra>(b->>'savings')::bigint then raise exception 'Not enough protected savings'; end if;
    legs:='[]'::jsonb;
    if covered>0 then legs:=legs||jsonb_build_array(jsonb_build_object('account',acct,'fund',fund,'cash',-covered,'committed',-covered,'loan',case when kind='lend' then covered else 0 end)); end if;
    if extra>0 then legs:=legs||jsonb_build_array(jsonb_build_object('account',acct,'cash',-extra,'savings',-extra)); end if;
   else
    if (b->>'savings')::bigint<amt then raise exception 'Not enough protected savings'; end if;
    legs:=jsonb_build_array(jsonb_build_object('account',acct,'cash',-amt,'savings',-amt,'loan',case when kind='lend' then amt else 0 end));
   end if;
   if kind='lend' then
    borrow:=nullif(trim(p_command->>'borrower'),''); if borrow is null then raise exception 'Borrower is required'; end if;
    insert into public.tracker_loans(owner_id,borrower,principal,source_fund,due_date) values(o,borrow,amt,fund,nullif(p_command->>'dueDate','')::date) returning id into loan;
   end if;
   perform public.tracker_post(o,kind,amt,d,note,legs,cycle,loan,null,key);
  elsif kind='income' then
   if amt<=0 or acct is null then raise exception 'Enter a positive income and account'; end if;
   perform public.tracker_post(o,'income',amt,d,note,jsonb_build_array(jsonb_build_object('account',acct,'cash',amt,'savings',amt)),null,null,null,key);
  elsif kind='classify' then
   if amt<=0 then raise exception 'Enter a positive amount'; end if;
   b:=public.tracker_balances(o); if amt>(b->>'unassigned')::bigint then raise exception 'Not enough unassigned cash'; end if;
   if fund is null then legs:=jsonb_build_array(jsonb_build_object('savings',amt,'unassigned',-amt));
   else legs:=jsonb_build_array(jsonb_build_object('fund',fund,'committed',amt,'unassigned',-amt)); end if;
   perform public.tracker_post(o,'classification',amt,d,note,legs,null,null,null,key);
  elsif kind='refund' then
   ev:=nullif(p_command->>'event','')::uuid;
   select * into original from public.tracker_events te where te.id=ev and te.owner_id=o and te.kind in ('spend','settle');
   if not found then raise exception 'Choose an original expense'; end if;
   if exists(select 1 from public.tracker_events where reverses=ev) then raise exception 'The original expense was reversed'; end if;
   if amt<=0 or acct is null then raise exception 'Enter a positive refund and receiving account'; end if;
   select coalesce(sum(te.amount),0) into paid from public.tracker_events te where te.related_event=ev and te.kind='refund';
   if amt>original.amount-paid then raise exception 'Refund exceeds the unrefunded expense'; end if;
   legs:='[]'::jsonb; total:=0; leg_index:=0;
   select count(*) into leg_count from public.tracker_legs where event_id=ev and cash_delta<0;
   for source_leg in select * from public.tracker_legs where event_id=ev and cash_delta<0 order by id loop
    leg_index:=leg_index+1;
    if leg_index=leg_count then portion:=amt-total;
    else portion:=((paid+amt)*abs(source_leg.cash_delta)/original.amount)-(paid*abs(source_leg.cash_delta)/original.amount); end if;
    if portion>0 then
     if source_leg.fund_id is not null and exists(select 1 from public.tracker_funds where id=source_leg.fund_id and active) then
      legs:=legs||jsonb_build_array(jsonb_build_object('account',acct,'fund',source_leg.fund_id,'cash',portion,'committed',portion));
     else
      legs:=legs||jsonb_build_array(jsonb_build_object('account',acct,'cash',portion,'savings',portion));
     end if;
    end if;
    total:=total+portion;
   end loop;
   new_ev:=public.tracker_post(o,'refund',amt,d,note,legs,null,null,null,key);
   update public.tracker_events set related_event=ev where id=new_ev;
  elsif kind='repay' then
   if amt<=0 or acct is null or loan is null then raise exception 'Enter a positive repayment, loan, and account'; end if;
   select principal-repaid-waived,source_fund into current_balance,fund from public.tracker_loans where id=loan for update;
   if amt>current_balance then raise exception 'Repayment exceeds outstanding principal'; end if;
   if fund is not null and (select active from public.tracker_funds where id=fund) then legs:=jsonb_build_array(jsonb_build_object('account',acct,'fund',fund,'cash',amt,'committed',amt,'loan',-amt));
   else legs:=jsonb_build_array(jsonb_build_object('account',acct,'cash',amt,'savings',amt,'loan',-amt)); end if;
   update public.tracker_loans set repaid=repaid+amt where id=loan;
   perform public.tracker_post(o,'repayment',amt,d,note,legs,null,loan,null,key);
  elsif kind='waive' then
   if loan is null then raise exception 'Select a loan'; end if;
   select principal-repaid-waived into amt from public.tracker_loans where id=loan for update;
   if amt<=0 then raise exception 'No principal remains'; end if;
   update public.tracker_loans set waived=waived+amt where id=loan;
   perform public.tracker_post(o,'waiver',amt,d,note,jsonb_build_array(jsonb_build_object('loan',-amt)),null,loan,null,key);
  elsif kind='transfer' then
   target:=nullif(p_command->>'destination','')::uuid;
   if amt<=0 or acct is null or target is null or acct=target then raise exception 'Choose two different accounts and a positive amount'; end if;
   if not exists(select 1 from public.tracker_accounts where id=target and owner_id=o and active) then raise exception 'Invalid destination'; end if;
   select coalesce(sum(cash_delta),0) into current_balance from public.tracker_legs where owner_id=o and account_id=acct;
   if amt>current_balance then raise exception 'Not enough recorded cash'; end if;
   perform public.tracker_post(o,'transfer',amt,d,note,jsonb_build_array(jsonb_build_object('account',acct,'cash',-amt,'unassigned',-amt),jsonb_build_object('account',target,'cash',amt,'unassigned',amt)),null,null,null,key);
  elsif kind='move_purpose' then
   if amt<=0 or fund is null then raise exception 'Choose a fund and positive amount'; end if;
   b:=public.tracker_balances(o);
   select coalesce(sum(fund_delta),0) into current_balance from public.tracker_legs where owner_id=o and fund_id=fund;
   if (p_command->>'direction')='release' then
    if current_balance<amt then raise exception 'Fund has insufficient remaining money'; end if;
    new_amount:=-amt;
   else
    if (b->>'savings')::bigint<amt then raise exception 'Not enough protected savings'; end if;
    new_amount:=amt;
   end if;
   perform public.tracker_post(o,'purpose_move',amt,d,note,jsonb_build_array(jsonb_build_object('fund',fund,'committed',new_amount,'savings',-new_amount)),null,null,null,key);
  elsif kind='reconcile' then
   if acct is null or amt<0 then raise exception 'Choose account and observed balance'; end if;
   if exists(select 1 from public.tracker_reconciliations where owner_id=o and account_id=acct and as_of=d) then raise exception 'This account already has a snapshot on that date'; end if;
   select coalesce(sum(cash_delta),0) into current_balance from public.tracker_legs where owner_id=o and account_id=acct;
   new_amount:=amt-current_balance;
   if new_amount=0 then
    insert into public.tracker_reconciliations(owner_id,account_id,as_of,observed,recorded_before) values(o,acct,d,amt,current_balance);
   else
    legs:='[]'::jsonb; total:=0;
    for row_item in select * from jsonb_array_elements(coalesce(p_command->'splits','[]'::jsonb)) loop
     fund:=nullif(row_item->>'fund','')::uuid; paid:=(row_item->>'amount')::bigint;
     if paid<=0 or fund is null or not exists(select 1 from public.tracker_funds where id=fund and owner_id=o) then raise exception 'Invalid reconciliation split'; end if;
     select coalesce(sum(fund_delta),0) into old_amount from public.tracker_legs where owner_id=o and fund_id=fund;
     if paid>old_amount then raise exception 'Fund has insufficient remaining money'; end if;
     total:=total+paid;
     legs:=legs||jsonb_build_array(jsonb_build_object('account',acct,'fund',fund,'cash',-paid,'committed',-paid));
    end loop;
    if new_amount<0 then
     if total > -new_amount then raise exception 'Classified funds exceed difference'; end if;
     paid:=-new_amount-total;
     if paid>0 then
      if (p_command->>'useSavings')::boolean is distinct from true then raise exception 'Confirm savings deduction for uncovered difference'; end if;
      b:=public.tracker_balances(o); if paid>(b->>'savings')::bigint then raise exception 'Not enough protected savings'; end if;
      legs:=legs||jsonb_build_array(jsonb_build_object('account',acct,'cash',-paid,'savings',-paid));
     end if;
    else
     if total<>0 then raise exception 'Positive difference cannot consume funds'; end if;
     legs:=jsonb_build_array(jsonb_build_object('account',acct,'cash',new_amount,'unassigned',new_amount));
    end if;
    ev:=public.tracker_post(o,'reconciliation',abs(new_amount),d,note,legs,null,null,null,key);
    insert into public.tracker_reconciliations(owner_id,account_id,as_of,observed,recorded_before,adjustment_event) values(o,acct,d,amt,current_balance,ev);
   end if;
   update public.tracker_accounts set confirmed_at=d,estimated=false where id=acct;
  elsif kind='reverse' then
   ev:=nullif(p_command->>'event','')::uuid;
   select * into original from public.tracker_events where id=ev and owner_id=o;
   if not found then raise exception 'Event not found'; end if;
   if original.kind not in ('spend','settle','purpose_move') then raise exception 'This event requires a guided correction'; end if;
   if exists(select 1 from public.tracker_events where reverses=ev) then raise exception 'Already reversed'; end if;
   if exists(select 1 from public.tracker_events te where te.related_event=ev and te.kind='refund') then raise exception 'Refund exists; correct it before reversing this expense'; end if;
   select coalesce(jsonb_agg(jsonb_build_object('account',account_id,'fund',fund_id,'cash',-cash_delta,'savings',-savings_delta,'committed',-fund_delta,'unassigned',-unassigned_delta,'loan',-loan_delta)),'[]'::jsonb) into legs from public.tracker_legs where event_id=ev;
   perform public.tracker_post(o,'reversal',original.amount,d,note,legs,original.cycle_id,original.loan_id,ev,key);
  elsif kind='close_cycle' then
   update public.tracker_cycles set status='closed',version=version+1 where id=cycle and status='approved' and owner_id=o;
   if not found then raise exception 'Approved cycle not found'; end if;
  elsif kind='rename_fund' then
   if fund is null or nullif(trim(p_command->>'name'),'') is null then raise exception 'Enter a fund name'; end if;
   if (p_command->>'active')::boolean is false and (select coalesce(sum(fund_delta),0) from public.tracker_legs where fund_id=fund)>0 then raise exception 'Release or consume remaining fund money before archiving'; end if;
   update public.tracker_funds set name=trim(p_command->>'name'),rule_amount=coalesce((p_command->>'ruleAmount')::bigint,rule_amount),active=coalesce((p_command->>'active')::boolean,active) where id=fund and owner_id=o;
  elsif kind='rename_account' then
   if acct is null or nullif(trim(p_command->>'name'),'') is null then raise exception 'Enter an account name'; end if;
   update public.tracker_accounts set name=trim(p_command->>'name') where id=acct and owner_id=o;
  else raise exception 'Unsupported command'; end if;
  if kind not in ('save_draft','rename_fund','rename_account','close_cycle') then
   update public.tracker_reconciliations r set status='needs_review' where r.owner_id=o and r.created_at<command_started and r.as_of>=d and exists(select 1 from public.tracker_events e join public.tracker_legs l on l.event_id=e.id where e.owner_id=o and e.posted_at>=command_started and l.account_id=r.account_id and l.cash_delta<>0);
  end if;
  update public.tracker_owners set version=version+1 where owner_id=o;
 end if;
 b:=public.tracker_balances(o);
 if (b->>'cash')::bigint <> (b->>'savings')::bigint+(b->>'committed')::bigint+(b->>'unassigned')::bigint then raise exception 'Ledger invariant failed'; end if;
 if (b->>'savings')::bigint<0 or (b->>'committed')::bigint<0 or (b->>'unassigned')::bigint<0 or (b->>'loans')::bigint<0 then raise exception 'Negative purpose balance'; end if;
 if exists(select 1 from public.tracker_accounts a where a.owner_id=o and (select coalesce(sum(cash_delta),0) from public.tracker_legs where account_id=a.id)<0) then raise exception 'Negative account cash'; end if;
 if exists(select 1 from public.tracker_funds f where f.owner_id=o and (select coalesce(sum(fund_delta),0) from public.tracker_legs where fund_id=f.id)<0) then raise exception 'Negative fund balance'; end if;
 return public.tracker_state();
end $$;
revoke all on function public.tracker_balances(uuid) from public, anon, authenticated;
grant execute on function public.tracker_state() to authenticated;
grant execute on function public.tracker_command(jsonb) to authenticated;
-- A backup is owner-scoped and contains posted history, not passwords or auth records.
create or replace function public.tracker_backup() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o uuid:=auth.uid(); result jsonb; begin
 if o is null then raise exception 'Unauthorized'; end if;
 select jsonb_build_object('schemaVersion',1,'exportedAt',now(),'owner',(select to_jsonb(x)-'owner_id' from public.tracker_owners x where owner_id=o),
 'accounts',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_accounts x where owner_id=o),'[]'::jsonb),
 'funds',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_funds x where owner_id=o),'[]'::jsonb),
 'cycles',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_cycles x where owner_id=o),'[]'::jsonb),
 'allocations',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_allocations x where owner_id=o),'[]'::jsonb),
 'loans',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_loans x where owner_id=o),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id' order by posted_at,id) from public.tracker_events x where owner_id=o),'[]'::jsonb),
 'legs',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_legs x where owner_id=o),'[]'::jsonb),
 'audit',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_audit x where owner_id=o),'[]'::jsonb),
 'reconciliations',coalesce((select jsonb_agg(to_jsonb(x)-'owner_id') from public.tracker_reconciliations x where owner_id=o),'[]'::jsonb)) into result;
 return result;
end $$;
create or replace function public.tracker_restore(p_backup jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); item jsonb; b jsonb; begin
 if o is null then raise exception 'Unauthorized'; end if;
 if (p_backup->>'schemaVersion')::int<>1 then raise exception 'Unsupported backup version'; end if;
 if exists(select 1 from public.tracker_owners where owner_id=o) then raise exception 'Restore requires a clean tracker dataset'; end if;
 if jsonb_typeof(p_backup->'accounts')<>'array' or jsonb_typeof(p_backup->'events')<>'array' or jsonb_typeof(p_backup->'legs')<>'array' then raise exception 'Invalid backup'; end if;
 insert into public.tracker_owners(owner_id,version,salary_default,opening_date,created_at) select o,version,salary_default,opening_date,created_at from jsonb_populate_record(null::public.tracker_owners,p_backup->'owner');
 for item in select * from jsonb_array_elements(p_backup->'accounts') loop
  insert into public.tracker_accounts select (jsonb_populate_record(null::public.tracker_accounts,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'funds') loop
  insert into public.tracker_funds select (jsonb_populate_record(null::public.tracker_funds,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'cycles') loop
  insert into public.tracker_cycles select (jsonb_populate_record(null::public.tracker_cycles,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'allocations') loop
  insert into public.tracker_allocations select (jsonb_populate_record(null::public.tracker_allocations,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'loans') loop
  insert into public.tracker_loans select (jsonb_populate_record(null::public.tracker_loans,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'events') loop
  insert into public.tracker_events select (jsonb_populate_record(null::public.tracker_events,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'legs') loop
  insert into public.tracker_legs select (jsonb_populate_record(null::public.tracker_legs,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'audit') loop
  insert into public.tracker_audit select (jsonb_populate_record(null::public.tracker_audit,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 for item in select * from jsonb_array_elements(p_backup->'reconciliations') loop
  insert into public.tracker_reconciliations select (jsonb_populate_record(null::public.tracker_reconciliations,item||jsonb_build_object('owner_id',o))).*;
 end loop;
 b:=public.tracker_balances(o);
 if (b->>'cash')::bigint<>(b->>'savings')::bigint+(b->>'committed')::bigint+(b->>'unassigned')::bigint then raise exception 'Backup fails accounting invariant'; end if;
 if (b->>'savings')::bigint<0 or (b->>'committed')::bigint<0 or (b->>'unassigned')::bigint<0 then raise exception 'Backup has negative balances'; end if;
 return public.tracker_state();
end $$;
revoke all on function public.tracker_state() from public, anon, authenticated;
revoke all on function public.tracker_command(jsonb) from public, anon, authenticated;
revoke all on function public.tracker_backup() from public, anon, authenticated;
revoke all on function public.tracker_restore(jsonb) from public, anon, authenticated;
grant execute on function public.tracker_state() to authenticated;
grant execute on function public.tracker_command(jsonb) to authenticated;
grant execute on function public.tracker_backup() to authenticated;
grant execute on function public.tracker_restore(jsonb) to authenticated;
