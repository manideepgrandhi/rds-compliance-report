(function(){"use strict";
var D=JSON.parse(document.getElementById("data").textContent),R=D.rows;
// v1.2.0 compliance exceptions (only when the report was built with an exceptions file): D.exc = per-scope counts
var EXC=!!D.exc,SC=["patch","backup"];
function xy(r,sc){return r[sc+"_exception"]==="yes";}
function xa(r,sc){return xy(r,sc)&&!!r[sc+"_exception_flag"];}
var XF={yes:function(r){return xy(r,"patch")||xy(r,"backup");},no:function(r){return !xy(r,"patch")&&!xy(r,"backup");},
 attn:function(r){return xa(r,"patch")||xa(r,"backup");},expired:function(r){return r.patch_exception==="expired"||r.backup_exception==="expired";}};
function lab(r,sc){return xy(r,sc)?"Compliant (exception)":r[sc+"_status"];}
function esc(s){return s==null?"":String(s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function uniq(f){var o={};R.forEach(function(r){o[f(r)]=1;});return Object.keys(o).sort();}
function tot(rs){var t={n:rs.length,pd:0,po:0,bo:0,bw:0,bn:0,bnyd:0,pf:0,bf:0,px:0,bx:0,pa:0,ba:0};rs.forEach(function(r){if(r.patch_status!=="No data")t.pd++;if(r.patch_status==="Compliant")t.po++;
 if(r.patch_status==="Non-compliant")t.pf++;if(r.backup_status==="Fail")t.bf++;if(xy(r,"patch"))t.px++;if(xy(r,"backup"))t.bx++;if(xa(r,"patch"))t.pa++;if(xa(r,"backup"))t.ba++;
 if(r.backup_status==="OK")t.bo++;if(r.backup_status==="Warning")t.bw++;if(r.backup_status==="No data")t.bn++;if(r.backup_status==="Not yet due")t.bnyd++;});
 t.pp=t.pd?Math.round(t.po*1000/t.pd)/10:null;t.bd=t.n-t.bn-t.bnyd;t.bp=t.bd?Math.round(100*(t.bo+t.bw)/t.bd):null;return t;}
function pct(v){return v==null?"No data":v+"%";}
function cls(s){return{"Compliant":"s-ok","OK":"s-ok","Warning":"s-warn","Non-compliant":"s-bad","Fail":"s-bad","Unknown":"s-unk","Not yet due":"s-nyd"}[s]||"s-nd";}
function badge(s){return '<span class="b '+cls(s)+'">'+esc(s)+'</span>';}
function xbadge(r,sc){return xy(r,sc)?'<span class="b s-ok exc" title="Exception until '+esc(r[sc+"_exception_expires"])+'; actual status '+esc(r[sc+"_actual_status"])+'">Compliant (exception)</span><div class="mut">actual '+esc(r[sc+"_actual_status"])+'</div>':badge(r[sc+"_status"]);}
function opts(id,label,vals){return '<select id="'+id+'" aria-label="'+label+'"><option value="">All '+label+'</option>'+vals.map(function(v){return '<option value="'+esc(v)+'">'+esc(v)+'</option>';}).join("")+'</select>';}
var ru=D.rules;
var h='<header><h1>RDS compliance report</h1><p>Generated '+esc(D.generated)+' &middot; v'+esc(D.tool)+' &middot; '+R.length+' server(s), '+D.accounts.length+' account(s)</p></header><main>';
if(EXC){var xw=[],xe=D.exc.patch.expired+D.exc.backup.expired,xu={};D.exc.patch.unmatched.concat(D.exc.backup.unmatched).forEach(function(u){xu[u.line]=u;});
 var xl=Object.keys(xu).map(function(k){return xu[k];});if(xe)xw.push(xe+" expired (evaluated normally; renew or remove)");
 var xd=D.exc.patch.no_data+D.exc.backup.no_data;if(xd)xw.push(xd+" not applied: no data for that server (stays No data)");
 if(xl.length)xw.push(xl.length+" matched no server: "+xl.map(function(u){return u.account+" "+u.identifier+" (line "+u.line+")";}).join(", "));
 if(xw.length)h+='<div class="excn" id="exc-note"><b>Exceptions file:</b> '+xw.map(esc).join(" &middot; ")+'</div>';
 document.head.insertAdjacentHTML("beforeend",'<style>.card{position:relative}.card .pop{display:none;position:absolute;left:0;top:100%;margin-top:4px;z-index:20;background:#333;color:#fff;border-radius:4px;padding:6px 9px;font-size:12px;white-space:nowrap;box-shadow:0 2px 8px rgba(0,0,0,.25)}.card:hover .pop{display:block}.card .pop div{display:flex;justify-content:space-between;gap:14px}.b.exc{background:#e3edf9;color:#1f5fa8}.xf{display:inline-block;background:#fff3c4;color:#7a5200;border:1px solid #f0d58c;border-radius:3px;padding:0 4px;font-size:11px}.xf.xe{background:#fde7e7;color:#b3261e;border-color:#f3b4b0}.xf.xn{background:#eee;color:#555;border-color:#ccc}.excn{background:#fff8e1;border:1px solid #f0d58c;border-radius:4px;padding:6px 10px;margin:8px 0}</style>');}
h+='<div class="cards" id="cards"></div>';
h+='<div class="filters">'+opts("fa","accounts",uniq(function(r){return r.account_id;}))+opts("fr","regions",uniq(function(r){return r.region;}))+opts("fe","engines",uniq(function(r){return r.engine_group;}))
 +'<select id="fs" aria-label="status"><option value="">All statuses</option><option value="pbad">Patch: not compliant</option><option value="pnd">Patch: no data</option><option value="bfail">Backup: fail</option><option value="bwarn">Backup: warning</option><option value="bnd">Backup: no data</option><option value="any">Any problem</option><option value="allok">Fully compliant</option></select>'
 +(EXC?'<select id="fx" aria-label="exceptions"><option value="">All exceptions</option><option value="yes">Exceptions only</option><option value="no">Non-exceptions</option><option value="attn">Expiring soon or no longer needed</option><option value="expired">Expired exceptions</option></select>':'')
 +'<input id="fq" type="search" placeholder="Search identifier, version, reason"><button id="reset">Reset</button><button id="csv" class="pri">Export CSV</button><span class="mut" id="cnt"></span></div>';
h+='<div class="grid3"><div><h2>Accounts</h2><div class="wrap" id="ta"></div></div><div><h2>Regions</h2><div class="wrap" id="tr"></div></div><div><h2>Engines</h2><div class="wrap" id="te"></div></div></div>';
h+='<h2>Servers</h2><div class="wrap" id="ts"></div>';
h+='<h2>Data collected</h2><div class="wrap"><table><thead><tr><th>Account</th><th>Patch data</th><th>Backup data</th><th>DocumentDB / Neptune data</th></tr></thead><tbody>'+D.accounts.map(function(a){return '<tr><td>'+esc(a.a)+'</td><td>'+(a.p?esc(a.p):badge("No data"))+'</td><td>'+(a.b?esc(a.b):badge("No data"))+'</td><td>'+(a.d?esc(a.d):badge("No data"))+'</td></tr>';}).join("")+'</tbody></table></div>';
h+='</main><footer>Patch: compliant when at most '+esc(ru.max_behind)+' minor version(s) behind'+(ru.oracle_any?' (Oracle: any patch line)':'')+'; Unknown counts in the %. Backup: '+esc(ru.daily)+' daily automated ('+esc(ru.daily_ret)+'d), weekly '+esc(ru.weekly_day)+' ('+esc(ru.weekly_ret)+'d), '+esc(ru.monthly)+' monthly first '+esc(ru.monthly_day)+' ('+esc(ru.monthly_ret)+'d); Warning counts as compliant; Not yet due and No data are left out of the %. Rules and status come unchanged from rds-patch-compliance and rds-backup-compliance.</footer>';
document.getElementById("app").innerHTML=h;
function $(i){return document.getElementById(i);}
function cur(){var a=$("fa").value,g=$("fr").value,e=$("fe").value,s=$("fs").value,q=$("fq").value.trim().toLowerCase(),x=EXC?$("fx").value:"";
 return R.filter(function(r){if(a&&r.account_id!==a)return false;if(x&&!XF[x](r))return false;if(g&&r.region!==g)return false;if(e&&r.engine_group!==e)return false;
  var pb=r.patch_status==="Non-compliant"||r.patch_status==="Unknown",bf=r.backup_status==="Fail"||r.backup_status==="Unknown";
  if(s==="pbad"&&!pb)return false;if(s==="pnd"&&r.patch_status!=="No data")return false;if(s==="bfail"&&!bf)return false;if(s==="bwarn"&&r.backup_status!=="Warning")return false;
  if(s==="bnd"&&r.backup_status!=="No data")return false;if(s==="any"&&!(pb||bf||r.backup_status==="Warning"||r.patch_status==="No data"||r.backup_status==="No data"))return false;
  if(s==="allok"&&!(r.patch_status==="Compliant"&&(r.backup_status==="OK"||r.backup_status==="Warning")))return false;
  if(q){var t=[r.account_id,r.region,r.engine,r.engine_group,r.identifier,r.current_version,r.latest_version,r.patch_status,r.patch_reason,r.backup_status,r.backup_reason].concat(EXC?[r.patch_exception_reason,r.backup_exception_reason]:[]).join(" ").toLowerCase();if(t.indexOf(q)<0)return false;}
  return true;});}
function group(rs,f){var o={};rs.forEach(function(r){var k=f(r);(o[k]=o[k]||[]).push(r);});return Object.keys(o).sort().map(function(k){return[k,tot(o[k])];});}
function gtable(th,rows){return '<table><thead><tr>'+th.map(function(x,i){return '<th'+(i>=th.length-3?' class="n"':'')+'>'+x+'</th>';}).join("")+'</tr></thead><tbody>'+(rows.length?rows.map(function(r){var t=r[1];return '<tr>'+r[0].map(function(c){return '<td>'+esc(c)+'</td>';}).join("")+'<td class="n">'+t.n+'</td><td class="n">'+pct(t.pp)+'</td><td class="n">'+pct(t.bp)+'</td></tr>';}).join(""):'<tr><td colspan="'+th.length+'" class="mut">No servers match the filters</td></tr>')+'</tbody></table>';}
function patchCell(r){if(r.versions_behind==null&&r.current_version==null)return xbadge(r,"patch");return xbadge(r,"patch")+' '+esc(r.current_version)+' &rarr; '+esc(r.latest_version==null?"?":r.latest_version)+(r.versions_behind!=null?' <span class="mut">('+esc(r.versions_behind)+' behind)</span>':'');}
function xn(n){return 'incl. '+n+' exception'+(n===1?'':'s');}
function pop(c,n,nc,k){if(!EXC)return '';return '<div class="l xs">'+xn(n)+'</div><div class="pop">'+[["Compliant",c+" ("+xn(n)+")"],["Non-compliant",nc]].concat(k?[["Exceptions expiring soon or no longer needed",k]]:[])
 .map(function(p){return '<div><span>'+esc(p[0])+'</span><b>'+esc(p[1])+'</b></div>';}).join("")+'</div>';}
function xcell(r){var o=SC.filter(function(sc){return r[sc+"_exception"]!=="no";}).map(function(sc){var f=r[sc+"_exception_flag"];
  return '<div><b>'+(sc==="patch"?"Patch":"Backup")+':</b> '+esc(r[sc+"_exception_reason"])+' <span class="mut">until '+esc(r[sc+"_exception_expires"])+'</span>'+(f?' <span class="xf'+(r[sc+"_exception"]==="expired"?' xe':r[sc+"_exception"]==="nodata"?' xn':'')+'">'+esc(f)+'</span>':'')+'</div>';});
 return o.length?o.join(""):'<span class="mut">-</span>';}
function draw(){var rs=cur(),t=tot(rs);
 $("cards").innerHTML='<div class="card" id="c-patch"><div class="l">Patch compliance</div><div class="v">'+pct(t.pp)+'</div><div class="l">'+t.po+' of '+t.pd+' server(s) with patch data</div>'+pop(t.po,t.px,t.pf,t.pa)+'</div>'
  +'<div class="card" id="c-backup"><div class="l">Backup compliance</div><div class="v">'+pct(t.bp)+'</div><div class="l">'+(t.bo+t.bw)+' of '+t.bd+' due server(s)'+(t.bw?', '+t.bw+' with warnings':'')+'</div>'+pop(t.bo+t.bw,t.bx,t.bf,t.ba)+'</div>'
  +'<div class="card" id="c-servers"><div class="l">Servers</div><div class="v">'+t.n+'</div><div class="l">'+(t.n-t.pd)+' no patch data, '+t.bn+' no backup data'+(t.bnyd?', '+t.bnyd+' not yet due':'')+'</div></div>';
 $("cnt").textContent=rs.length+" of "+R.length+" server(s)";
 var g3=["Servers","Patch %","Backup %"];
 $("ta").innerHTML=gtable(["Account"].concat(g3),group(rs,function(r){return r.account_id;}).map(function(x){return[[x[0]],x[1]];}));
 $("tr").innerHTML=gtable(["Account","Region"].concat(g3),group(rs,function(r){return r.account_id+"|"+r.region;}).map(function(x){return[x[0].split("|"),x[1]];}));
 $("te").innerHTML=gtable(["Engine"].concat(g3),group(rs,function(r){return r.engine_group;}).map(function(x){return[[x[0]],x[1]];}));
 $("ts").innerHTML='<table><thead><tr><th>Account</th><th>Region</th><th>Engine</th><th>Identifier</th><th>Patch</th><th>Backup</th><th>Backup reason</th>'+(EXC?'<th>Exception</th>':'')+'</tr></thead><tbody>'+(rs.length?rs.map(function(r){
  return '<tr><td>'+esc(r.account_id)+'</td><td>'+esc(r.region)+'</td><td>'+esc(r.engine_group)+'</td><td>'+esc(r.identifier)+'</td><td class="p">'+patchCell(r)+(r.patch_reason?'<div class="mut">'+esc(r.patch_reason)+'</div>':'')+'</td><td>'+xbadge(r,"backup")+'</td><td class="r">'+esc(r.backup_reason)+'</td>'+(EXC?'<td class="r">'+xcell(r)+'</td>':'')+'</tr>';}).join(""):'<tr><td colspan="'+(EXC?8:7)+'" class="mut">No servers match the filters</td></tr>')+'</tbody></table>';}
function cell(v){var s=v==null?"":String(v);if(/^[=+\-@\t\r]/.test(s))s="'"+s;
 if(/^\d+(\.\d+)*$/.test(s)&&s.indexOf(".")>=0)s="=\""+s+"\"";return '"'+s.replace(/"/g,'""')+'"';}
function csv(){var rs=cur(),c=D.cols,L=[c.map(cell).join(",")];
 rs.forEach(function(r){L.push([r.account_id,r.region,r.engine,r.engine_group,r.type,r.identifier,EXC?lab(r,"patch"):r.patch_status,r.current_version,r.latest_version,r.versions_behind,r.patch_reason,EXC?lab(r,"backup"):r.backup_status,r.backup_reason]
  .concat(c.slice(13).map(function(k){return r[k];})).map(cell).join(","));});
 var b=new Blob(["\ufeff"+L.join("\r\n")+"\r\n"],{type:"text/csv;charset=utf-8"}),a=document.createElement("a");a.href=URL.createObjectURL(b);
 a.download="rds_compliance_servers_"+(D.acct?D.acct+"_":"")+"filtered_"+D.stamp+".csv";document.body.appendChild(a);a.click();setTimeout(function(){URL.revokeObjectURL(a.href);a.remove();},0);}
var FL=["fa","fr","fe","fs"].concat(EXC?["fx"]:[]);
FL.forEach(function(i){$(i).addEventListener("change",draw);});$("fq").addEventListener("input",draw);
$("reset").addEventListener("click",function(){FL.forEach(function(i){$(i).value="";});$("fq").value="";draw();});
$("csv").addEventListener("click",csv);window.__rcr={cur:cur,tot:tot,csvCell:cell};draw();})();
