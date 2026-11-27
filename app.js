import { PRICES } from './prices.js';
import { currentUserId } from './user.js';

// Which billing period the page opens on. Product thinks annual-first might sell more
// (it shows the lower monthly-equivalent price), but nobody has tested it.
const DEFAULT_BILLING = 'monthly';

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
  button.addEventListener('click', () => {
    const params = new URLSearchParams({ plan: button.dataset.plan, billing: document.body.dataset.billing, user: currentUserId() });
    location.href = `checkout.html?${params}`;
  });
}

render(DEFAULT_BILLING);
