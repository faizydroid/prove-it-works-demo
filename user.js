// Visitors aren't logged in on the pricing page, so each browser gets a stable anonymous id.
// Analytics and checkout both use it.
export function currentUserId() {
  let id = localStorage.getItem('acme_uid');
  if (!id) {
    id = `anon-${crypto.randomUUID()}`;
    localStorage.setItem('acme_uid', id);
  }
  return id;
}
