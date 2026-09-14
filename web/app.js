const parcels = document.querySelector("#parcels");
const errorBox = document.querySelector("#error");
const form = document.querySelector("#create-form");
const formStatus = document.querySelector("#form-status");

const esc = value => String(value).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const label = value => value.replaceAll("_", " ");
const key = prefix => `${prefix}-${crypto.randomUUID()}`;

async function request(path, options = {}) {
  const response = await fetch(path, options);
  if (!response.ok) {
    const problem = await response.json().catch(() => ({}));
    throw new Error(problem.detail || `Request failed (${response.status})`);
  }
  return response.status === 204 ? null : response.json();
}

function parcelCard(parcel) {
  const events = parcel.events.map(e => `<li>${esc(label(e.toStatus))}<br><small>${new Date(e.occurredAt).toLocaleString()}</small></li>`).join("");
  const disabled = parcel.status === "delivered" ? "disabled" : "";
  return `<article class="card"><span class="pill">${esc(label(parcel.status))}</span><p class="tracking">${esc(parcel.trackingId)}</p>
    <h3>${esc(parcel.recipientName)}</h3><p class="address">${esc(parcel.deliveryAddress)}</p>
    <ol class="timeline">${events || `<li>${esc(label(parcel.status))}</li>`}</ol>
    <div class="card-actions"><button data-advance="${esc(parcel.trackingId)}" ${disabled}>Advance delivery</button></div></article>`;
}

async function load() {
  errorBox.hidden = true;
  parcels.setAttribute("aria-busy", "true");
  try {
    const data = await request("/api/v1/parcels");
    parcels.innerHTML = data.items.map(parcelCard).join("");
  } catch (error) {
    errorBox.textContent = error.message; errorBox.hidden = false;
  } finally { parcels.removeAttribute("aria-busy"); }
}

form.addEventListener("submit", async event => {
  event.preventDefault(); formStatus.textContent = "Creating…";
  const data = Object.fromEntries(new FormData(form));
  try {
    const parcel = await request("/api/v1/parcels", {method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":key("ui-create")},body:JSON.stringify(data)});
    form.reset(); formStatus.textContent = `Created ${parcel.trackingId}`; await load();
  } catch (error) { formStatus.textContent = error.message; }
});
document.querySelector("#refresh").addEventListener("click", load);
parcels.addEventListener("click", async event => {
  const tracking = event.target.dataset.advance;
  if (!tracking) return;
  event.target.disabled = true;
  try {
    await request(`/api/v1/parcels/${encodeURIComponent(tracking)}/commands/advance`, {method:"POST",headers:{"Idempotency-Key":key("ui-advance")}});
    setTimeout(load, 1200);
  } catch (error) { errorBox.textContent = error.message; errorBox.hidden = false; event.target.disabled = false; }
});
load();
