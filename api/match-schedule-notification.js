import { timingSafeEqual } from "node:crypto";
import nodemailer from "nodemailer";
import { createClient } from "@supabase/supabase-js";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function equalSecret(value, expected){
  if(!value || !expected)return false;
  const a=Buffer.from(value),b=Buffer.from(expected);
  return a.length===b.length && timingSafeEqual(a,b);
}
function result(status,body){return Response.json(body,{status,headers:{"Cache-Control":"no-store"}});}
export function makeHandler({dbFactory=createClient,mailerFactory=nodemailer.createTransport}={}){
  return async function handle(request){
    if(request.method!=="POST")return result(405,{error:"Method not allowed"});
    if(!equalSecret(request.headers.get("x-match-schedule-webhook-secret"),
      process.env.MATCH_SCHEDULE_WEBHOOK_SECRET))return result(401,{error:"Unauthorized"});
    const required=["SUPABASE_URL","SUPABASE_SERVICE_ROLE_KEY","SMTP_HOST","SMTP_PORT",
      "SMTP_USER","SMTP_PASSWORD","SMTP_FROM"];
    if(required.some(key=>!process.env[key]))return result(503,{error:"Missing email configuration"});
    let payload;
    try{payload=await request.json();}catch{return result(400,{error:"Invalid JSON"});}
    if(payload?.type!=="INSERT" || payload?.schema!=="public" ||
       payload?.table!=="match_schedule_events" || !UUID.test(payload?.record?.id||""))
      return result(400,{error:"Invalid event"});
    const db=dbFactory(process.env.SUPABASE_URL,process.env.SUPABASE_SERVICE_ROLE_KEY,{
      auth:{persistSession:false,autoRefreshToken:false}
    });
    const {data, error}=await db.rpc("match_schedule_notification_secure",
      {requested_event_id:payload.record.id});
    if(error)return result(500,{error:"Could not load scheduling notification"});
    if(!Array.isArray(data) || !data.length)return result(200,{skipped:"No recipients or match closed"});
    const item=data[0];
    if(!["proposed","confirmed"].includes(item.event_type) ||
       !item.proposed_start || !item.venue || !item.challenger_name || !item.challenged_name)
      return result(500,{error:"Incomplete event"});
    const recipients=[...new Set(data.map(r=>String(r.recipient_email||"").trim().toLowerCase())
      .filter(e=>/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)))].slice(0,2);
    if(!recipients.length)return result(200,{skipped:"No assigned emails"});
    const port=Number(process.env.SMTP_PORT);
    if(!Number.isInteger(port) || port<1 || port>65535)return result(503,{error:"Invalid SMTP port"});
    const mailer=mailerFactory({
      host:process.env.SMTP_HOST,port,secure:port===465,requireTLS:port!==465,
      auth:{user:process.env.SMTP_USER,pass:process.env.SMTP_PASSWORD},
      connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000
    });
    const eventTime=new Date(item.proposed_start);
    if(Number.isNaN(eventTime.getTime()))return result(500,{error:"Invalid schedule time"});
    const time=eventTime.toLocaleString("en-CA",{
      timeZone:"America/Vancouver",year:"numeric",month:"short",day:"numeric",
      hour:"numeric",minute:"2-digit",timeZoneName:"short"
    });
    const confirmed=item.event_type==="confirmed";
    const subject=confirmed?"PaddleLadder match time confirmed":"PaddleLadder match time proposed";
    const body=[
      `Match: ${item.challenger_name} vs. ${item.challenged_name}`,
      confirmed?"The opposing team confirmed your proposed time.":"The opposing team has proposed a match time.",
      `Date and time: ${time}`,`Location: ${item.venue}`,"",
      confirmed?"Please confirm your court booking separately.":"Sign in to confirm this time or suggest an alternative.",
      "Open PaddleLadder: https://vpaladder.pickleballpatrol.ca/","",
      "A proposed time does not reserve a court."
    ].join("\n");
    let sent=0,duplicate=0,failed=0;
    for(const email of recipients){
      const {error:claimError}=await db.from("match_schedule_email_notices")
        .insert({event_id:payload.record.id,email});
      if(claimError?.code==="23505"){duplicate++;continue;}
      if(claimError){failed++;continue;}
      try{
        await mailer.sendMail({from:process.env.SMTP_FROM,to:email,subject,text:body});
        await db.from("match_schedule_email_notices")
          .update({sent_at:new Date().toISOString()})
          .eq("event_id",payload.record.id).eq("email",email);
        sent++;
      }catch(e){
        console.error("Schedule notification failed",e);
        await db.from("match_schedule_email_notices").delete()
          .eq("event_id",payload.record.id).eq("email",email);
        failed++;
      }
    }
    return result(failed?503:200,{sent,duplicate,failed});
  };
}
export function makeVercelHandler(options){
  const handle=makeHandler(options);
  return async function(req,res){
    const body=typeof req.body==="string"||Buffer.isBuffer(req.body)?req.body:
      JSON.stringify(req.body??{});
    const response=await handle(new Request("https://vpaladder.pickleballpatrol.ca/api/match-schedule-notification",{
      method:req.method,
      headers:{"content-type":"application/json",
        "x-match-schedule-webhook-secret":req.headers?.["x-match-schedule-webhook-secret"]||""},
      body:req.method==="POST"?body:undefined
    }));
    res.setHeader("Cache-Control","no-store");
    res.status(response.status).json(await response.json());
  };
}
export default makeVercelHandler();
