const KEY = "brussels.wtf:personal-feed:v1"
const TYPES = new Set(["dossier", "person", "legal_entity", "commune"])
const COMMUNES = new Set(["ixelles", "uccle", "forest", "city-of-brussels"])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/, ENTERPRISE = /^\d{10}$/
const EVENTS = {
 dossier:new Set(["linked_agenda_item","decision","correction","merge","split"]),
 person:new Set(["verified_public_mandate","verified_management_role","relevant_council_item"]),
 legal_entity:new Set(["verified_management_role","contract_award","relevant_council_item"]),
 commune:new Set(["published_meeting_page","publication_revision_new_decisions"])
}
export function validTarget(t) {
 if (!t || !TYPES.has(t.type) || typeof t.id!=="string") return false
 return t.type==="person"?UUID.test(t.id):t.type==="legal_entity"?ENTERPRISE.test(t.id):t.type==="commune"?COMMUNES.has(t.id):SLUG.test(t.id)
}
const empty=()=>({follows:[],notifications:[]})
export function load(storage) { try { const v=JSON.parse(storage.getItem(KEY)); if(!v||!Array.isArray(v.follows)||!Array.isArray(v.notifications))return empty(); return {follows:v.follows.filter(t=>validTarget(t)&&typeof t.importedAt==="string"&&!Number.isNaN(Date.parse(t.importedAt))),notifications:v.notifications.filter(n=>validNotification(n,"https://brussels.wtf"))} } catch(_){return empty()} }
function exactPublicUrl(value, origin) { try { if(typeof value!=="string"||/[\\\x00-\x1f]/.test(value)||/%2f|%5c/i.test(value))return null; const base=new URL(origin), u=new URL(value,base); if(u.origin!==base.origin||u.username||u.password)return null; if(!/^\/(?:dossiers\/[a-z0-9-]+|people\/[0-9a-f-]{36}|companies\/\d{10}|meetings\/(?:ixelles|uccle|forest|city-of-brussels)\/[A-Za-z0-9._~-]+)$/.test(u.pathname))return null; if(!/^(fr|nl|en)$/.test(u.searchParams.get("lang")||""))return null; return `${u.pathname}${u.search}${u.hash}` }catch(_){return null} }
function validNotification(n,origin){return n&&typeof n.id==="string"&&n.id.length>0&&validTarget(n.target)&&EVENTS[n.target.type].has(n.eventType)&&typeof n.publicEventId==="string"&&n.publicEventId.length>0&&((n.eventType.startsWith("verified_")||n.eventType==="contract_award")?typeof n.factId==="string":typeof n.revisionId==="string")&&typeof n.title==="string"&&typeof n.occurredAt==="string"&&!Number.isNaN(Date.parse(n.occurredAt))&&exactPublicUrl(n.url,origin)!==null}
function save(storage,v){try{storage.setItem(KEY,JSON.stringify(v))}catch(_){} return v}
export function importSnapshot(storage,targets,now=new Date()){const state=load(storage),fresh=targets.filter(validTarget).map(t=>({type:t.type,id:t.id,importedAt:now.toISOString()})),m=new Map([...fresh,...state.follows].map(t=>[`${t.type}:${t.id}`,t]));return save(storage,{...state,follows:[...m.values()]})}
export function ingestUpdates(storage,updates,{origin="https://brussels.wtf"}={}){const state=load(storage),followed=new Set(state.follows.map(t=>`${t.type}:${t.id}`)),m=new Map(state.notifications.map(n=>[n.id,n])); for(const raw of updates){if(validNotification(raw,origin)&&followed.has(`${raw.target.type}:${raw.target.id}`)&&!m.has(raw.id)){m.set(raw.id,{...raw,url:exactPublicUrl(raw.url,origin),readAt:null})}} return save(storage,{...state,notifications:[...m.values()]})}
export function markRead(storage,id,now){const state=load(storage);return save(storage,{...state,notifications:state.notifications.map(n=>n.id===id?{...n,readAt:now.toISOString()}:n)})}
function anniversary(value){const d=new Date(value),day=d.getUTCDate();d.setUTCDate(1);d.setUTCFullYear(d.getUTCFullYear()+1);const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,last));return d}
export function cleanup(storage,now){const state=load(storage);return save(storage,{...state,notifications:state.notifications.filter(n=>anniversary(n.occurredAt)>=now)})}
export function enhancePersonalFeed(window,document,storage,{now=()=>new Date(),origin=window.location.origin}={}){
 const form=document.querySelector("[data-follow-import]"); if(form)form.addEventListener("submit",e=>{e.preventDefault();const selected=[...form.querySelectorAll("input[data-follow-target]:checked")].map(i=>({type:i.dataset.type,id:i.dataset.identifier}));importSnapshot(storage,selected,now());window.location.assign(`/feed${window.location.search}`)})
 const feed=document.querySelector("[data-personal-feed]");if(!feed)return;
 const render=()=>{feed.textContent="";const state=cleanup(storage,now());for(const n of state.notifications.sort((a,b)=>b.occurredAt.localeCompare(a.occurredAt))){if(!validNotification(n,origin))continue;const li=document.createElement("li"),a=document.createElement("a");a.textContent=n.title;a.href=n.url;if(!n.readAt)li.dataset.unread="true";a.addEventListener("click",()=>markRead(storage,n.id,now()));li.appendChild(a);feed.appendChild(li)}};render()
 if(window.fetch){const state=load(storage),csrf=document.querySelector('meta[name="csrf-token"]')?.content;window.fetch("/feed/updates",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-csrf-token":csrf},body:JSON.stringify({targets:state.follows.map(t=>({type:t.type,id:t.id,importedAt:t.importedAt}))})}).then(r=>r.ok?r.json():{updates:[]}).then(body=>{ingestUpdates(storage,body.updates||[],{origin});render()}).catch(()=>{})}
}
