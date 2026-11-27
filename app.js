import { PRICES } from './prices.js';
import { currentUserId } from './user.js';

// Which billing period the page opens on. Annual won the A/B test against monthly
// (15.5% vs 10.2% of visitors started checkout), so the page opens on annual for everyone.
const DEFAULT_BILLING = 'annual';

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
