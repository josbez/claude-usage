
(function() {
const deliver = (s) => { DELIVER };
fetch('/api/bootstrap', {credentials:'include', headers:{Accept:'application/json'}})
.then(r => r.json())
.then(async d => {
    const acct = d.account || {};
    const email = acct.email_address || acct.email || '';
    // Only name, plan and a shared org's name leave the page — never the whole bootstrap payload
    const name = acct.display_name || acct.full_name || '';
    const memberships = acct.memberships || [];
    let best = null;
    for (const m of memberships) {
        const org = m.organization || {};
        const orgId = org.uuid || null;
        if (!orgId) continue;
        // Raw plan data; core.plan_label() turns it into a label (observed values only)
        const plan = {label: org.plan_display_label || org.plan_display_name || '',
                      capabilities: org.capabilities || [], tier: org.rate_limit_tier || '',
                      raven: org.raven_type || ''};
        // Org name only for shared (Team) orgs: personal orgs are named after the e-mail address
        const orgName = org.raven_type ? (org.name || '') : '';
        try {
            const r = await fetch('/api/organizations/' + orgId + '/usage?cedar_ember=1', {
                credentials: 'include',
                headers: {Accept: 'application/json'}
            });
            if (!r.ok) continue;
            const data = await r.json();
            if (data.five_hour === undefined) continue;
            const util = (data.five_hour && data.five_hour.utilization) || 0;
            if (!best || util > best.util) {
                best = {util, org_id: orgId, account_email: email, plan, org_name: orgName, data};
            }
        } catch(e) { continue; }
    }
    if (best) {
        // Block fields (taak 28): only logged when non-empty; location in bootstrap is unconfirmed, so check root and the chosen org
        const bootstrapFields = {};
        const bestOrg = ((memberships.find(m => (m.organization || {}).uuid === best.org_id)) || {}).organization || {};
        ['access_block', 'billing_issue', 'subscription_pause', 'api_disabled_reason', 'api_disabled_until'].forEach(f => {
            const v = bestOrg[f] || d[f];
            if (v) bootstrapFields[f] = v;
        });
        deliver(JSON.stringify({ok: true, org_id: best.org_id,
                                account_email: best.account_email,
                                account_name: name, account_plan: best.plan,
                                account_org: best.org_name,
                                bootstrap_fields: bootstrapFields,
                                data: best.data}));
    } else {
        deliver(JSON.stringify({ok: false, error: 'no org with usage data'}));
    }
})
.catch(e => { deliver(JSON.stringify({ok: false, error: e.message})); });
})();
