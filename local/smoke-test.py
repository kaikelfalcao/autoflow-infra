#!/usr/bin/env python3
"""Happy path E2E contra cluster kind local (via Kong em http://localhost:8080)."""
import json
import random
import subprocess
import time
import urllib.request
import urllib.error


BASE = "http://localhost:8080"


def gen_cpf() -> tuple[str, str]:
    n = [random.randint(0, 9) for _ in range(9)]
    s = sum((10 - i) * n[i] for i in range(9))
    d1 = (s * 10) % 11 % 10
    n.append(d1)
    s = sum((11 - i) * n[i] for i in range(10))
    d2 = (s * 10) % 11 % 10
    n.append(d2)
    raw = ''.join(map(str, n))
    return raw, f"{raw[:3]}.{raw[3:6]}.{raw[6:9]}-{raw[9:]}"


def gen_plate() -> str:
    letters = ''.join(random.choices('ABCDEFGHJKLMNPQRSTUVWXYZ', k=3))
    return f"{letters}{random.randint(0,9)}A{random.randint(10,99)}"


def http(method: str, path: str, body=None, headers=None):
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Content-Type', 'application/json')
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            text = r.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        return {'_error': True, 'status': e.code, 'body': json.loads(e.read().decode() or '{}')}


def kubectl_psql(query: str, db: str = 'saga', user: str = 'saga_user', password: str = 'saga_pass') -> str:
    """Roda psql via kubectl exec no pod do Postgres."""
    out = subprocess.run(
        ['kubectl', 'exec', '-n', 'autoflow', 'postgres-0', '--',
         'psql', '-U', user, '-d', db, '-tAc', query],
        env={**__import__('os').environ, 'PGPASSWORD': password},
        capture_output=True, text=True,
    )
    return out.stdout.strip()


def kubectl_mongo(db: str, query: str, user: str, pwd: str) -> str:
    pod = f'mongodb-{db}-0'
    auth = f'-u {user} -p {pwd} --authenticationDatabase admin'
    out = subprocess.run(
        ['kubectl', 'exec', '-n', 'autoflow', pod, '--',
         'sh', '-c', f'mongosh "mongodb://localhost:27017/{db}" {auth} --quiet --eval "{query}"'],
        capture_output=True, text=True,
    )
    return out.stdout.strip()


def hdr(s): print(f"\n──── {s} ────")
def ok(s):  print(f"  ✓ {s}")
def arrow(s): print(f"  → {s}")
def show(k, v): print(f"    {k:18s} {v}")


# ── 1. Admin login
hdr("1/12  Admin loga via Kong → identity-service")
r = http('POST', '/auth/login/admin', {'email': 'admin@autoflow.com', 'password': 'Admin@123'})
assert 'token' in r, f"Login failed: {r}"
admin_token = r['token']
ok(f"JWT admin emitido (exp={r['expiresIn']}s)")

# ── 2. Cria peça
hdr("2/12  Cria peça no catalog-service")
part = http('POST', '/parts', {
    'name': 'Pastilha de Freio Bosch', 'category': 'BRAKE', 'unit': 'UN',
    'stockQuantity': 100, 'minimumStock': 10})
assert 'id' in part, f"Part create failed: {part}"
part_id = part['id']
ok(f"Part: id={part_id} sku={part['sku']}")

# ── 3. Customer + Vehicle
cpf_raw, cpf_fmt = gen_cpf()
plate = gen_plate()

hdr("3/12  Cria cliente no order-service")
cust = http('POST', '/customers', {
    'documentType': 'CPF', 'documentNumber': cpf_fmt, 'name': 'Maria Aparecida',
    'email': 'maria@example.com', 'phone': '11988887777'})
assert 'id' in cust, f"Customer failed: {cust}"
cust_id = cust['id']
ok(f"Customer: id={cust_id} doc={cpf_fmt}")

hdr("4/12  Cria veículo")
veh = http('POST', '/vehicles', {
    'customerId': cust_id, 'plate': plate, 'brand': 'Volkswagen',
    'model': 'Polo', 'year': 2023, 'color': 'Branco', 'mileageKm': 12500})
assert 'plate' in veh, f"Vehicle failed: {veh}"
ok(f"Vehicle: plate={plate}")

# ── 5. Customer login via CPF
hdr("5/12  Customer faz login via CPF")
arrow("identity → HTTP interna → order /customers/by-document/:cpf")
clogin = http('POST', '/auth/login/customer', {'cpf': cpf_fmt})
assert 'token' in clogin, f"Customer login failed: {clogin}"
ok(f"Customer JWT (exp={clogin['expiresIn']}s)")

stock_before = http('GET', f'/parts/{part_id}')

# ── 6. Order lifecycle
hdr("6/12  Abre OS e adiciona PART")
order = http('POST', '/orders', {
    'customerCpf': cpf_raw, 'customerName': 'Maria Aparecida',
    'customerPhone': '11988887777', 'vehiclePlate': plate,
    'vehicleBrand': 'Volkswagen', 'vehicleModel': 'Polo', 'vehicleYear': 2023})
order_id = order['id']

http('PATCH', f'/orders/{order_id}/status', {'status': 'DIAGNOSIS', 'changedBy': 'api'})
http('POST', f'/orders/{order_id}/items', {
    'itemType': 'PART', 'catalogItemId': part_id,
    'name': 'Pastilha', 'unitPrice': 189.50, 'quantity': 4})
http('POST', f'/orders/{order_id}/budget', {'discount': 58, 'validDays': 7})
ok(f"Order {order_id} com budget gerado")

# ── 7. Aprovação → SAGA
hdr("7/12  Aprova budget ⚡ dispara SAGA")
http('POST', f'/orders/{order_id}/budget/approve')
arrow("order publica order.budget.approved")
arrow("saga-orchestrator consome, publica stock.reserve-stock")
arrow("catalog reserva, publica stock.stock-reserved")
time.sleep(4)

saga_st = kubectl_psql(f"SELECT status FROM saga_states WHERE order_id='{order_id}'")
stock_after_res = http('GET', f'/parts/{part_id}')
show("Saga status:", saga_st)
show("Estoque:", f"stock={stock_after_res['stockQuantity']} reserved={stock_after_res['reservedQuantity']}")
assert saga_st == 'RESERVED', f"Saga should be RESERVED, got {saga_st}"

# ── 8. Conclui execução
hdr("8/12  Conclui execução → consume + payment.requested")
http('POST', f'/orders/{order_id}/execution/complete')
time.sleep(4)

saga_st = kubectl_psql(f"SELECT status FROM saga_states WHERE order_id='{order_id}'")
charge = http('GET', f'/billing/charges/order/{order_id}')
order_curr = http('GET', f'/orders/{order_id}')
show("Saga:", saga_st)
show("Order:", order_curr['status'])
show("Charge:", f"{charge.get('status','?')} R$ {charge.get('totalCents',0)/100:.2f}")

assert saga_st == 'CONSUMED', f"Saga should be CONSUMED, got {saga_st}"
assert charge.get('status') == 'PENDING', f"Charge should be PENDING, got {charge}"
mp_id = charge['checkoutUrl'].split('/')[-1]
ok(f"MP Payment ID (mock): {mp_id}")

# ── 9. Pagamento
hdr("9/12  Customer 'paga' (mock MP)")
http('POST', f'/billing/mock/approve/{mp_id}')
http('POST', '/billing/webhook/mercadopago', {
    'type': 'payment', 'action': 'payment.updated', 'data': {'id': mp_id}})
time.sleep(4)

charge = http('GET', f'/billing/charges/order/{order_id}')
order_curr = http('GET', f'/orders/{order_id}')
show("Charge:", charge['status'])
show("Order:", order_curr['status'])

assert charge['status'] == 'APPROVED'
assert order_curr['status'] == 'PAID'

# ── 10. Verifica notificações no Mongo do notification-service
hdr("10/12 Notificações persistidas no MongoDB")
notif_query = f"db.notifications.find({{orderId:'{order_id}'}}, {{template:1,channel:1,_id:0}}).toArray().forEach(n => print(JSON.stringify(n)))"
notif_log = kubectl_mongo('notification', notif_query, 'notification_admin', 'notification_pass')
notifs = [json.loads(line) for line in notif_log.split('\n') if line.startswith('{')]
for n in notifs:
    print(f"      {n['channel']:6s} {n['template']}")
assert len(notifs) >= 5, f"Should have ≥5 notifications, got {len(notifs)}"

# ── 11. Verifica movements no catalog
hdr("11/12 Movements de estoque no catalog")
mvt_log = kubectl_mongo('catalog',
    f"db.movements.find({{osId:'{order_id}'}}, {{type:1,quantity:1,_id:0}}).toArray().forEach(m => print(JSON.stringify(m)))",
    'catalog_admin', 'catalog_pass')
mvts = [json.loads(line) for line in mvt_log.split('\n') if line.startswith('{')]
for m in mvts:
    print(f"      {m['type']:9s} qty={m['quantity']}")
assert len(mvts) == 2, f"Should have RESERVE+OUT, got {len(mvts)}"

# ── 12. Verificação final
hdr("12/12 Verificação final consolidada")
show("Identity JWT:", "admin + customer emitidos")
show("Order final:", order_curr['status'])
show("Saga final:", saga_st)
show("Charge final:", charge['status'])
show("Stock final:", f"{stock_after_res['stockQuantity'] - 4} (era 100)")
show("Notifications:", f"{len(notifs)} eventos")
show("Movements:", f"{len(mvts)} (RESERVE + OUT)")

print()
print("═══════════════════════════════════════════════════════════════")
print("   ✅ HAPPY PATH E2E COMPLETO no cluster kind")
print("═══════════════════════════════════════════════════════════════")
