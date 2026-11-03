(function(){"use strict";
var D=JSON.parse(document.getElementById("data").textContent),R=D.rows;
function esc(s){return s==null?"":String(s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function uniq(f){var o={};R.forEach(function(r){o[f(r)]=1;});return Object.keys(o).sort();}
function tot(rs){var t={n:rs.length,pd:0,po:0,bo:0,bw:0,bn:0,bnyd:0};rs.forEach(function(r){if(r.patch_status!=="No data")t.pd++;if(r.patch_status==="Compliant")t.po++;
 if(r.backup_status==="OK")t.bo++;if(r.backup_status==="Warning")t.bw++;if(r.backup_status==="No data")t.bn++;if(r.backup_status==="Not yet due")t.bnyd++;});
 t.pp=t.pd?Math.round(t.po*1000/t.pd)/10:null;t.bd=t.n-t.bn-t.bnyd;t.bp=t.bd?Math.round(100*(t.bo+t.bw)/t.bd):null;return t;}
function pct(v){return v==null?"No data":v+"%";}
function cls(s){return{"Compliant":"s-ok","OK":"s-ok","Warning":"s-warn","Non-compliant":"s-bad","Fail":"s-bad","Unknown":"s-unk","Not yet due":"s-nyd"}[s]||"s-nd";}
function badge(s){return '<span class="b '+cls(s)+'">'+esc(s)+'</span>';}
function opts(id,label,vals){return '<select id="'+id+'" aria-label="'+label+'"><option value="">All '+label+'</option>'+vals.map(function(v){return '<option value="'+esc(v)+'">'+esc(v)+'</option>';}).join("")+'</select>';}
var ru=D.rules;
var h='<header><h1>RDS compliance report</h1><p>Generated '+esc(D.generated)+' &middot; v'+esc(D.tool)+' &middot; '+R.length+' server(s), '+D.accounts.length+' account(s)</p></header><main>';
h+='<div class="cards" id="cards"></div>';
h+='<div class="filters">'+opts("fa","accounts",uniq(function(r){return r.account_id;}))+opts("fr","regions",uniq(function(r){return r.region;}))+opts("fe","engines",uniq(function(r){return r.engine_group;}))
 +'<select id="fs" aria-label="status"><option value="">All statuses</option><option value="pbad">Patch: not compliant</option><option value="pnd">Patch: no data</option><option value="bfail">Backup: fail</option><option value="bwarn">Backup: warning</option><option value="bnd">Backup: no data</option><option value="any">Any problem</option><option value="allok">Fully compliant</option></select>'
 +'<input id="fq" type="search" placeholder="Search identifier, version, reason"><button id="reset">Reset</button><button id="csv" class="pri">Export CSV</button><span class="mut" id="cnt"></span></div>';
h+='<div class="grid3"><div><h2>Accounts</h2><div class="wrap" id="ta"></div></div><div><h2>Regions</h2><div class="wrap" id="tr"></div></div><div><h2>Engines</h2><div class="wrap" id="te"></div></div></div>';
h+='<h2>Servers</h2><div class="wrap" id="ts"></div>';
h+='<h2>Data collected</h2><div class="wrap"><table><thead><tr><th>Account</th><th>Patch data</th><th>Backup data</th><th>DocumentDB / Neptune data</th></tr></thead><tbody>'+D.accounts.map(function(a){return '<tr><td>'+esc(a.a)+'</td><td>'+(a.p?esc(a.p):badge("No data"))+'</td><td>'+(a.b?esc(a.b):badge("No data"))+'</td><td>'+(a.d?esc(a.d):badge("No data"))+'</td></tr>';}).join("")+'</tbody></table></div>';
h+='</main><footer>Patch: compliant when at most '+esc(ru.max_behind)+' minor version(s) behind'+(ru.oracle_any?' (Oracle: any patch line)':'')+'; Unknown counts in the %. Backup: '+esc(ru.daily)+' daily automated ('+esc(ru.daily_ret)+'d), weekly '+esc(ru.weekly_day)+' ('+esc(ru.weekly_ret)+'d), '+esc(ru.monthly)+' monthly first '+esc(ru.monthly_day)+' ('+esc(ru.monthly_ret)+'d); Warning counts as compliant; Not yet due and No data are left out of the %. Rules and status come unchanged from rds-patch-compliance and rds-backup-compliance.</footer>';
document.getElementById("app").innerHTML=h;
function $(i){return document.getElementById(i);}
function cur(){var a=$("fa").value,g=$("fr").value,e=$("fe").value,s=$("fs").value,q=$("fq").value.trim().toLowerCase();
 return R.filter(function(r){if(a&&r.account_id!==a)return false;if(g&&r.region!==g)return false;if(e&&r.engine_group!==e)return false;
  var pb=r.patch_status==="Non-compliant"||r.patch_status==="Unknown",bf=r.backup_status==="Fail"||r.backup_status==="Unknown";
  if(s==="pbad"&&!pb)return false;if(s==="pnd"&&r.patch_status!=="No data")return false;if(s==="bfail"&&!bf)return false;if(s==="bwarn"&&r.backup_status!=="Warning")return false;
  if(s==="bnd"&&r.backup_status!=="No data")return false;if(s==="any"&&!(pb||bf||r.backup_status==="Warning"||r.patch_status==="No data"||r.backup_status==="No data"))return false;
  if(s==="allok"&&!(r.patch_status==="Compliant"&&(r.backup_status==="OK"||r.backup_status==="Warning")))return false;
  if(q){var t=[r.account_id,r.region,r.engine,r.engine_group,r.identifier,r.current_version,r.latest_version,r.patch_status,r.patch_reason,r.backup_status,r.backup_reason].join(" ").toLowerCase();if(t.indexOf(q)<0)return false;}
  return true;});}
function group(rs,f){var o={};rs.forEach(function(r){var k=f(r);(o[k]=o[k]||[]).push(r);});return Object.keys(o).sort().map(function(k){return[k,tot(o[k])];});}
function gtable(th,rows){return '<table><thead><tr>'+th.map(function(x,i){return '<th'+(i>=th.length-3?' class="n"':'')+'>'+x+'</th>';}).join("")+'</tr></thead><tbody>'+(rows.length?rows.map(function(r){var t=r[1];return '<tr>'+r[0].map(function(c){return '<td>'+esc(c)+'</td>';}).join("")+'<td class="n">'+t.n+'</td><td class="n">'+pct(t.pp)+'</td><td class="n">'+pct(t.bp)+'</td></tr>';}).join(""):'<tr><td colspan="'+th.length+'" class="mut">No servers match the filters</td></tr>')+'</tbody></table>';}
function patchCell(r){if(r.versions_behind==null&&r.current_version==null)return badge(r.patch_status);return badge(r.patch_status)+' '+esc(r.current_version)+' &rarr; '+esc(r.latest_version==null?"?":r.latest_version)+(r.versions_behind!=null?' <span class="mut">('+esc(r.versions_behind)+' behind)</span>':'');}
function draw(){var rs=cur(),t=tot(rs);
 $("cards").innerHTML='<div class="card" id="c-patch"><div class="l">Patch compliance</div><div class="v">'+pct(t.pp)+'</div><div class="l">'+t.po+' of '+t.pd+' server(s) with patch data</div></div>'
  +'<div class="card" id="c-backup"><div class="l">Backup compliance</div><div class="v">'+pct(t.bp)+'</div><div class="l">'+(t.bo+t.bw)+' of '+t.bd+' due server(s)'+(t.bw?', '+t.bw+' with warnings':'')+'</div></div>'
  +'<div class="card" id="c-servers"><div class="l">Servers</div><div class="v">'+t.n+'</div><div class="l">'+(t.n-t.pd)+' no patch data, '+t.bn+' no backup data'+(t.bnyd?', '+t.bnyd+' not yet due':'')+'</div></div>';
 $("cnt").textContent=rs.length+" of "+R.length+" server(s)";
 var g3=["Servers","Patch %","Backup %"];
 $("ta").innerHTML=gtable(["Account"].concat(g3),group(rs,function(r){return r.account_id;}).map(function(x){return[[x[0]],x[1]];}));
 $("tr").innerHTML=gtable(["Account","Region"].concat(g3),group(rs,function(r){return r.account_id+"|"+r.region;}).map(function(x){return[x[0].split("|"),x[1]];}));
 $("te").innerHTML=gtable(["Engine"].concat(g3),group(rs,function(r){return r.engine_group;}).map(function(x){return[[x[0]],x[1]];}));
 $("ts").innerHTML='<table><thead><tr><th>Account</th><th>Region</th><th>Engine</th><th>Identifier</th><th>Patch</th><th>Backup</th><th>Backup reason</th></tr></thead><tbody>'+(rs.length?rs.map(function(r){
  return '<tr><td>'+esc(r.account_id)+'</td><td>'+esc(r.region)+'</td><td>'+esc(r.engine_group)+'</td><td>'+esc(r.identifier)+'</td><td class="p">'+patchCell(r)+(r.patch_reason?'<div class="mut">'+esc(r.patch_reason)+'</div>':'')+'</td><td>'+badge(r.backup_status)+'</td><td class="r">'+esc(r.backup_reason)+'</td></tr>';}).join(""):'<tr><td colspan="7" class="mut">No servers match the filters</td></tr>')+'</tbody></table>';}
function cell(v){var s=v==null?"":String(v);if(/^[=+\-@\t\r]/.test(s))s="'"+s;
 if(/^\d+(\.\d+)*$/.test(s)&&s.indexOf(".")>=0)s="=\""+s+"\"";return '"'+s.replace(/"/g,'""')+'"';}
function csv(){var rs=cur(),c=D.cols,L=[c.map(cell).join(",")];
 rs.forEach(function(r){L.push([r.account_id,r.region,r.engine,r.engine_group,r.type,r.identifier,r.patch_status,r.current_version,r.latest_version,r.versions_behind,r.patch_reason,r.backup_status,r.backup_reason].map(cell).join(","));});
 var b=new Blob(["\ufeff"+L.join("\r\n")+"\r\n"],{type:"text/csv;charset=utf-8"}),a=document.createElement("a");a.href=URL.createObjectURL(b);
 a.download="rds_compliance_servers_"+(D.acct?D.acct+"_":"")+"filtered_"+D.stamp+".csv";document.body.appendChild(a);a.click();setTimeout(function(){URL.revokeObjectURL(a.href);a.remove();},0);}
["fa","fr","fe","fs"].forEach(function(i){$(i).addEventListener("change",draw);});$("fq").addEventListener("input",draw);
$("reset").addEventListener("click",function(){["fa","fr","fe","fs"].forEach(function(i){$(i).value="";});$("fq").value="";draw();});
$("csv").addEventListener("click",csv);window.__rcr={cur:cur,tot:tot,csvCell:cell};draw();})();
