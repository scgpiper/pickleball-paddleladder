import test from "node:test";
import assert from "node:assert/strict";
import { makeHandler, makeVercelHandler } from "../api/match-schedule-notification.js";

const originalEnv={...process.env};
const eventId="a63aa2d1-f65a-45aa-92bb-e7b7b447146d";
function setup(){
  Object.assign(process.env,{
    MATCH_SCHEDULE_WEBHOOK_SECRET:"test-match-secret",
    SUPABASE_URL:"https://example.supabase.co",SUPABASE_SERVICE_ROLE_KEY:"secret",
    SMTP_HOST:"smtp.example.com",SMTP_PORT:"465",SMTP_USER:"mailer@example.com",
    SMTP_PASSWORD:"secret",SMTP_FROM:"PaddleLadder <mailer@example.com>"
  });
}
function event(secret="test-match-secret"){
  return new Request("https://example.com/api/match-schedule-notification",{
    method:"POST",headers:{"content-type":"application/json","x-match-schedule-webhook-secret":secret},
    body:JSON.stringify({type:"INSERT",schema:"public",table:"match_schedule_events",record:{id:eventId}})
  });
}
function mocks(type="proposed"){
  const sent=[],claims=new Set();
  const db={
    rpc:async(name,args)=>{
      assert.equal(name,"match_schedule_notification_secure");
      assert.equal(args.requested_event_id,eventId);
      return {data:["first@example.com","second@example.com"].map(email=>({
        event_type:type,proposed_start:"2026-11-30T02:00:00Z",
        venue:"VPA facility",challenger_name:"Wojo",challenged_name:"Get Them",
        recipient_email:email
      })),error:null};
    },
    from(name){
      assert.equal(name,"match_schedule_email_notices");
      return {
        insert:async({email})=>{
          if(claims.has(email))return {error:{code:"23505"}};
          claims.add(email);return {error:null};
        },
        update:()=>({eq:()=>({eq:async()=>({error:null})})}),
        delete:()=>({eq:()=>({eq:async()=>({error:null})})})
      };
    }
  };
  const mailer={sendMail:async message=>{sent.push(message);}};
  return {sent,handler:makeHandler({dbFactory:()=>db,mailerFactory:()=>mailer}),
    vercelHandler:makeVercelHandler({dbFactory:()=>db,mailerFactory:()=>mailer})};
}
test.after(()=>{process.env=originalEnv;});
test("rejects unauthorized and malformed scheduling webhooks",async()=>{
  setup();const {handler}=mocks();
  assert.equal((await handler(event("bad"))).status,401);
  assert.equal((await handler(new Request("https://example.com",{method:"GET"}))).status,405);
});
test("proposals notify opposing players once and format Pacific Standard Time",async()=>{
  setup();const {handler,sent}=mocks();
  assert.equal((await handler(event())).status,200);
  assert.equal(sent.length,2);
  assert.match(sent[0].text,/Nov 29, 2026.*PST/);
  assert.match(sent[0].text,/confirm this time or suggest an alternative/i);
  assert.equal((await handler(event())).status,200);
  assert.equal(sent.length,2);
});
test("confirmed notifications ask for court booking separately",async()=>{
  setup();const {handler,sent}=mocks("confirmed");
  assert.equal((await handler(event())).status,200);
  assert.match(sent[0].subject,/confirmed/);
  assert.match(sent[0].text,/court booking separately/i);
});
test("Vercel wrapper accepts Supabase event payload",async()=>{
  setup();const {vercelHandler,sent}=mocks();
  const res={setHeader(){},status(value){this.statusCode=value;return this;},json(value){this.body=value;return this;}};
  await vercelHandler({method:"POST",headers:{"x-match-schedule-webhook-secret":"test-match-secret"},
    body:{type:"INSERT",schema:"public",table:"match_schedule_events",record:{id:eventId}}},res);
  assert.equal(res.statusCode,200);
  assert.equal(sent.length,2);
});

test("court booking notification reaches opposing players",async()=>{
  setup();
  const {handler,sent}=mocks("booked");
  assert.equal((await handler(event())).status,200);
  assert.equal(sent.length,2);
  assert.match(sent[0].subject,/court booking reported/i);
  assert.match(sent[0].text,/booking status is reported by a player/i);
});
