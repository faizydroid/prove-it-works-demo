import flagsmith from 'https://cdn.jsdelivr.net/npm/@flagsmith/flagsmith@12.6.0/index.mjs';
import { PRICES } from './prices.js';
import { currentUserId } from './user.js';

// Which billing period the page opens on. Product thinks annual-first might sell more
// (it shows the lower monthly-equivalent price). Experiment `pricing_default_billing`
// serves 'monthly' (control) or 'annual'; fall back to monthly if the flag is unavailable.
const FALLBACK_BILLING = 'monthly';
const FLAGSMITH_ENVIRONMENT_ID = 'dMF4K5LSSqPndCs8DprMKJ'; // client-side key: public by design

const buttons = document.querySelectorAll('[data-billing]');

function render(billing) {
  for (const b of buttons) b.setAttribute('aria-checked', String(b.dataset.billing === billing));
  for (const plan of document.querySelectorAll('.plan')) {
    const p = PRICES[plan.dataset.plan][billing];
    plan.querySelector('.amount').textContent = `$${p.perMonth}`;
    plan.querySelector('.billed').textContent = billing === 'annual' ? `Billed $${p.total} yearly` : 'Billed monthly';
  }
  document.body.dataset.billing = billing;
}

for (const b of buttons) b.addEventListener('click', () => render(b.dataset.billing));

for (const button of document.querySelectorAll('.checkout')) {
  button.addEventListener('click', async () => {
    const params = new URLSearchParams({ plan: button.dataset.plan, billing: document.body.dataset.billing, user: currentUserId() });
    flagsmith.trackEvent('checkout_started');
    await flagsmith.flushEvents();
    location.href = `checkout.html?${params}`;
  });
}

window.addEventListener('pagehide', () => flagsmith.flushEvents());

await flagsmith.init({ environmentID: FLAGSMITH_ENVIRONMENT_ID, identity: currentUserId(), enableEvents: true });
const flag = flagsmith.getExperimentFlag('pricing_default_billing'); // records the exposure
const billing = flag?.value === 'annual' ? 'annual' : FALLBACK_BILLING;
render(billing);
