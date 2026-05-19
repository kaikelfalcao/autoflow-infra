#!/usr/bin/env python3
"""Cenários E2E contra o cluster autoflow local via Kong em :8080.

Subcomandos: happy | bad-stock | bad-payment.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("AUTOFLOW_BASE_URL", "http://localhost:8080")
NS = "autoflow"
# Se setado, é injetado como X-Correlation-Id em toda chamada HTTP. Útil pra
# demos de rastreamento distribuído — propaga via envelope de eventos RMQ.
DEMO_CID = os.environ.get("AUTOFLOW_CORRELATION_ID", "")

C_RESET = "\033[0m"
C_CYAN = "\033[1;36m"
C_GREEN = "\033[0;32m"
C_YELLOW = "\033[1;33m"
C_RED = "\033[0;31m"
C_DIM = "\033[2m"
C_BLUE = "\033[0;34m"
C_MAGENTA = "\033[0;35m"


def banner(title: str) -> None:
    print()
    print(f"{C_CYAN}{'═' * 72}{C_RESET}")
    print(f"{C_CYAN}  {title}{C_RESET}")
    print(f"{C_CYAN}{'═' * 72}{C_RESET}")


def step(num: str, title: str) -> None:
    print()
    print(f"{C_BLUE}━━━━ {num} {title} ━━━━{C_RESET}")


def ok(msg: str) -> None:
    print(f"  {C_GREEN}✓{C_RESET} {msg}")


def warn(msg: str) -> None:
    print(f"  {C_YELLOW}⚠{C_RESET} {msg}")


def err(msg: str) -> None:
    print(f"  {C_RED}✗{C_RESET} {msg}")


def arrow(msg: str) -> None:
    print(f"  {C_DIM}→ {msg}{C_RESET}")


def kv(k: str, v: object) -> None:
    print(f"    {k:18s} {v}")


def section(label: str) -> None:
    print(f"\n  {C_MAGENTA}[{label}]{C_RESET}")


def http(method: str, path: str, body=None, headers=None, show: bool = True):
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    if show:
        section(f"HTTP {method} {path}")
        if body is not None:
            print(f"  {C_DIM}> body:{C_RESET} {json.dumps(body, ensure_ascii=False)}")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if DEMO_CID:
        req.add_header("X-Correlation-Id", DEMO_CID)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            text = r.read().decode()
            result = json.loads(text) if text else {}
            if show:
                pretty = json.dumps(result, ensure_ascii=False, indent=2)
                if len(pretty) > 600:
                    pretty = pretty[:600] + "…(truncated)"
                print(f"  {C_DIM}< {r.status}:{C_RESET} {pretty}")
            return result
    except urllib.error.HTTPError as e:
        body_text = e.read().decode() or "{}"
        try:
            parsed = json.loads(body_text)
        except json.JSONDecodeError:
            parsed = {"raw": body_text}
        if show:
            print(f"  {C_RED}< {e.code}:{C_RESET} {json.dumps(parsed, ensure_ascii=False)}")
        return {"_error": True, "status": e.code, "body": parsed}


def _has_local_postgres() -> bool:
    out = subprocess.run(
        ["kubectl", "get", "pod", "postgres-0", "-n", NS, "--no-headers"],
        capture_output=True, text=True,
    )
    return out.returncode == 0


def kubectl_psql(query: str, db: str, user: str, password: str) -> str:
    if _has_local_postgres():
        out = subprocess.run(
            ["kubectl", "exec", "-n", NS, "postgres-0", "--",
             "env", f"PGPASSWORD={password}",
             "psql", "-U", user, "-d", db, "-tAc", query],
            capture_output=True, text=True,
        )
        return out.stdout.strip()
    # AWS / RDS — usa pod efêmero
    host = os.environ.get("PG_HOST") or _resolve_pg_host_from_secret(db, user)
    if not host:
        return ""
    name = f"psql-q-{int(time.time() * 1000) % 1_000_000_000}"
    out = subprocess.run(
        ["kubectl", "run", name, "--rm", "-i", "--restart=Never",
         "--image=postgres:16-alpine", "--quiet", "--command",
         "--env", f"PGPASSWORD={password}", "--",
         "psql", "-h", host, "-U", user, "-d", db, "-tAc", query],
        capture_output=True, text=True,
    )
    return (out.stdout or "").strip()


_PG_HOST_CACHE: dict[str, str] = {}


def _resolve_pg_host_from_secret(_db: str, _user: str) -> str:
    if "rds" in _PG_HOST_CACHE:
        return _PG_HOST_CACHE["rds"]
    # Pega DB_HOST do secret do payment (todos compartilham RDS)
    out = subprocess.run(
        ["kubectl", "get", "secret", "payment-secrets", "-n", NS,
         "-o", "jsonpath={.data.DB_HOST}"],
        capture_output=True, text=True,
    )
    import base64 as _b
    host = ""
    if out.returncode == 0 and out.stdout:
        try:
            host = _b.b64decode(out.stdout).decode()
        except Exception:
            host = ""
    _PG_HOST_CACHE["rds"] = host
    return host


def _mongo_password(db: str) -> str:
    cache_key = f"mongo_{db}_pw"
    if cache_key in _PG_HOST_CACHE:
        return _PG_HOST_CACHE[cache_key]
    secret = f"mongodb-{db}-auth"
    out = subprocess.run(
        ["kubectl", "get", "secret", secret, "-n", NS,
         "-o", "jsonpath={.data.MONGO_INITDB_ROOT_PASSWORD}"],
        capture_output=True, text=True,
    )
    import base64 as _b
    pw = ""
    if out.returncode == 0 and out.stdout:
        try:
            pw = _b.b64decode(out.stdout).decode()
        except Exception:
            pw = ""
    _PG_HOST_CACHE[cache_key] = pw
    return pw


def kubectl_mongo(db: str, query: str, user: str, pwd: str = "") -> str:
    # Sempre prefere a senha do secret — ignora pwd hardcoded (legado local).
    real_pwd = _mongo_password(db) or pwd
    pod = f"mongodb-{db}-0"
    auth = f"-u {user} -p {real_pwd} --authenticationDatabase admin"
    out = subprocess.run(
        ["kubectl", "exec", "-n", NS, pod, "--",
         "sh", "-c",
         f'mongosh "mongodb://localhost:27017/{db}" {auth} --quiet --eval "{query}"'],
        capture_output=True, text=True,
    )
    return out.stdout.strip()


def logs_since(deployment: str, seconds: int = 6, grep: str | None = None,
               max_lines: int = 12) -> None:
    """Imprime logs recentes de um deployment, opcionalmente filtrados."""
    section(f"logs {deployment} (últimos {seconds}s)")
    cmd = ["kubectl", "logs", "-n", NS, f"deploy/{deployment}",
           f"--since={seconds}s", "--tail=200", "--prefix=false"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    lines = out.stdout.splitlines()
    if grep:
        gpat = grep.lower()
        lines = [l for l in lines if gpat in l.lower()]
    if not lines:
        print(f"  {C_DIM}(sem linhas novas){C_RESET}")
        return
    for line in lines[-max_lines:]:
        print(f"  {C_DIM}│{C_RESET} {line}")


def gen_cpf() -> tuple[str, str]:
    n = [random.randint(0, 9) for _ in range(9)]
    s = sum((10 - i) * n[i] for i in range(9))
    d1 = (s * 10) % 11 % 10
    n.append(d1)
    s = sum((11 - i) * n[i] for i in range(10))
    d2 = (s * 10) % 11 % 10
    n.append(d2)
    raw = "".join(map(str, n))
    return raw, f"{raw[:3]}.{raw[3:6]}.{raw[6:9]}-{raw[9:]}"


def gen_plate() -> str:
    letters = "".join(random.choices("ABCDEFGHJKLMNPQRSTUVWXYZ", k=3))
    return f"{letters}{random.randint(0,9)}A{random.randint(10,99)}"


def _saga_password() -> str:
    if _has_local_postgres():
        return "saga_pass"
    if "saga_pw" in _PG_HOST_CACHE:
        return _PG_HOST_CACHE["saga_pw"]
    out = subprocess.run(
        ["kubectl", "get", "secret", "saga-secrets", "-n", NS,
         "-o", "jsonpath={.data.DATABASE_PASSWORD}"],
        capture_output=True, text=True,
    )
    import base64 as _b
    pw = ""
    if out.returncode == 0 and out.stdout:
        try:
            pw = _b.b64decode(out.stdout).decode()
        except Exception:
            pw = ""
    _PG_HOST_CACHE["saga_pw"] = pw
    return pw


def saga_status_of(order_id: str) -> str:
    return kubectl_psql(
        f"SELECT status FROM saga_states WHERE order_id='{order_id}'",
        db="saga", user="saga_user", password=_saga_password())


def saga_reason_of(order_id: str) -> str:
    return kubectl_psql(
        f"SELECT failure_reason FROM saga_states WHERE order_id='{order_id}'",
        db="saga", user="saga_user", password=_saga_password())


def check_kong(timeout_s: int = 60) -> None:
    # Kong Ingress Controller leva alguns segundos para descobrir os Services
    # após o cluster subir; até lá responde 503 ring-balancer.
    deadline = time.time() + timeout_s
    last = "(sem tentativa)"
    while time.time() < deadline:
        try:
            req = urllib.request.Request(
                f"{BASE}/auth/login/admin", method="POST",
                data=b'{}', headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=3)
            return
        except urllib.error.HTTPError as e:
            if e.code in (400, 401):
                return
            last = f"HTTP {e.code}"
        except Exception as e:
            last = repr(e)
        time.sleep(2)
    err(f"Kong não está pronto em {BASE} após {timeout_s}s (último: {last}). Rode ./reset.sh primeiro.")
    sys.exit(1)


def scenario_happy() -> None:
    banner("HAPPY PATH — fluxo completo OS → saga → pagamento → notificação")
    check_kong()

    step("1/12", "Admin loga (POST /auth/login/admin → identity-service)")
    r = http("POST", "/auth/login/admin",
             {"email": "admin@autoflow.com", "password": "Admin@123"})
    assert "token" in r, f"Login admin falhou: {r}"
    admin_token = r["token"]
    ok(f"JWT admin emitido (expiresIn={r['expiresIn']}s)")

    step("2/12", "Cria peça (POST /parts → catalog-service)")
    part = http("POST", "/parts", {
        "name": "Pastilha de Freio Bosch", "category": "BRAKE", "unit": "UN",
        "stockQuantity": 100, "minimumStock": 10})
    assert "id" in part
    part_id = part["id"]
    ok(f"Part id={part_id} sku={part['sku']}")

    cpf_raw, cpf_fmt = gen_cpf()
    plate = gen_plate()
    step("3/12", "Cria cliente (POST /customers → order-service)")
    cust = http("POST", "/customers", {
        "documentType": "CPF", "documentNumber": cpf_fmt, "name": "Maria Aparecida",
        "email": "maria@example.com", "phone": "11988887777"})
    cust_id = cust["id"]
    ok(f"Customer id={cust_id} doc={cpf_fmt}")

    step("4/12", "Cria veículo (POST /vehicles → order-service)")
    http("POST", "/vehicles", {
        "customerId": cust_id, "plate": plate, "brand": "Volkswagen",
        "model": "Polo", "year": 2023, "color": "Branco", "mileageKm": 12500})
    ok(f"Vehicle plate={plate}")

    step("5/12", "Customer loga via CPF (POST /auth/login/customer)")
    arrow("identity-service chama order-service /customers/by-document/:cpf via HTTP interna")
    clogin = http("POST", "/auth/login/customer", {"cpf": cpf_fmt})
    ok(f"Customer JWT (expiresIn={clogin['expiresIn']}s)")

    step("6/12", "Abre OS, adiciona PART, gera budget")
    order = http("POST", "/orders", {
        "customerCpf": cpf_raw, "customerName": "Maria Aparecida",
        "customerPhone": "11988887777", "vehiclePlate": plate,
        "vehicleBrand": "Volkswagen", "vehicleModel": "Polo", "vehicleYear": 2023})
    order_id = order["id"]
    http("PATCH", f"/orders/{order_id}/status",
         {"status": "DIAGNOSIS", "changedBy": "api"})
    http("POST", f"/orders/{order_id}/items", {
        "itemType": "PART", "catalogItemId": part_id, "name": "Pastilha",
        "unitPrice": 189.50, "quantity": 4})
    http("POST", f"/orders/{order_id}/budget", {"discount": 58, "validDays": 7})
    ok(f"Order {order_id} criada com budget")

    step("7/12", "Aprova budget — DISPARA SAGA via RabbitMQ")
    http("POST", f"/orders/{order_id}/budget/approve")
    arrow("order publica order.events::order.budget.approved")
    arrow("saga-orchestrator consome → publica oficina.commands::stock.reserve-stock")
    arrow("catalog-service consome → reserva → publica oficina.replies::stock.stock-reserved")
    time.sleep(4)
    logs_since("saga-orchestrator", 8, grep="budget-approved")
    logs_since("catalog-service", 8, grep="reserve")

    saga_st = saga_status_of(order_id)
    stock = http("GET", f"/parts/{part_id}", show=False)
    section("DB state após reserva")
    kv("saga_states.status:", saga_st)
    kv("part stock/reserved:",
       f"stock={stock['stockQuantity']} reserved={stock['reservedQuantity']}")
    assert saga_st == "RESERVED", f"saga deveria ser RESERVED, está {saga_st}"
    ok("Saga RESERVED; estoque reservado")

    step("8/12", "Conclui execução — consume + payment.requested")
    http("POST", f"/orders/{order_id}/execution/complete")
    arrow("order publica order.events::order.execution.completed")
    arrow("saga publica stock.consume-stock + payment.requested")
    arrow("catalog consome estoque; payment-service cria charge")
    time.sleep(4)
    logs_since("saga-orchestrator", 8, grep="execution|consume|payment")
    logs_since("payment-service", 8, grep="MOCK|charge|preference")

    saga_st = saga_status_of(order_id)
    charge = http("GET", f"/billing/charges/order/{order_id}")
    order_curr = http("GET", f"/orders/{order_id}", show=False)
    section("DB state após payment.requested")
    kv("saga_states.status:", saga_st)
    kv("orders.status:", order_curr["status"])
    kv("charges.status:", f"{charge['status']} R$ {charge['totalCents']/100:.2f}")
    assert saga_st == "CONSUMED"
    assert charge["status"] == "PENDING"
    mp_id = charge["checkoutUrl"].split("/")[-1]
    ok(f"Charge PENDING; MP Payment ID (mock): {mp_id}")

    step("9/12", "Customer paga (mock MP approve + webhook)")
    http("POST", f"/billing/mock/approve/{mp_id}")
    http("POST", "/billing/webhook/mercadopago",
         {"type": "payment", "action": "payment.updated", "data": {"id": mp_id}})
    time.sleep(4)
    logs_since("payment-service", 8, grep="approved|webhook|payment-confirmed")

    charge = http("GET", f"/billing/charges/order/{order_id}", show=False)
    order_curr = http("GET", f"/orders/{order_id}", show=False)
    section("DB state após webhook")
    kv("charges.status:", charge["status"])
    kv("orders.status:", order_curr["status"])
    assert charge["status"] == "APPROVED"
    assert order_curr["status"] == "PAID"
    ok("Charge APPROVED; Order PAID")

    step("10/12", "Notificações persistidas no Mongo")
    arrow("notification-service consome eventos e grava no Mongo")
    q = (f"db.notifications.find({{orderId:'{order_id}'}},"
         f"{{template:1,channel:1,_id:0}}).toArray()"
         f".forEach(n => print(JSON.stringify(n)))")
    notif_log = kubectl_mongo("notification", q, "notification_admin", "notification_pass")
    notifs = [json.loads(l) for l in notif_log.split("\n") if l.startswith("{")]
    section("notification-service.notifications")
    for n in notifs:
        print(f"    {n['channel']:6s} {n['template']}")
    assert len(notifs) >= 5
    ok(f"{len(notifs)} notificações registradas")

    step("11/12", "Movements de estoque no Mongo do catalog")
    q = (f"db.movements.find({{osId:'{order_id}'}},"
         f"{{type:1,quantity:1,_id:0}}).toArray()"
         f".forEach(m => print(JSON.stringify(m)))")
    mvt_log = kubectl_mongo("catalog", q, "catalog_admin", "catalog_pass")
    mvts = [json.loads(l) for l in mvt_log.split("\n") if l.startswith("{")]
    section("catalog-service.movements")
    for m in mvts:
        print(f"    {m['type']:9s} qty={m['quantity']}")
    assert len(mvts) == 2
    ok("RESERVE + OUT registrados")

    step("12/12", "Resumo consolidado")
    stock_final = http("GET", f"/parts/{part_id}", show=False)
    kv("Identity:", "admin + customer JWTs emitidos")
    kv("Order final:", order_curr["status"])
    kv("Saga final:", saga_st)
    kv("Charge final:", charge["status"])
    kv("Stock final:", f"{stock_final['stockQuantity']} (era 100)")
    kv("Reserved final:", stock_final["reservedQuantity"])
    kv("Notifications:", len(notifs))
    kv("Movements:", len(mvts))

    banner("✅ HAPPY PATH COMPLETO — 12/12")


def scenario_bad_stock() -> None:
    banner("BAD PATH 1 — estoque insuficiente → saga falha → order CANCELLED")
    check_kong()

    step("1/6", "Admin loga")
    r = http("POST", "/auth/login/admin",
             {"email": "admin@autoflow.com", "password": "Admin@123"})
    assert "token" in r
    ok("JWT admin OK")

    step("2/6", "Cria peça com estoque PEQUENO (5 unidades)")
    part = http("POST", "/parts", {
        "name": "Disco de Freio Raro", "category": "BRAKE", "unit": "UN",
        "stockQuantity": 5, "minimumStock": 1})
    part_id = part["id"]
    ok(f"Part id={part_id} stock=5")

    step("3/6", "Cria cliente + veículo")
    cpf_raw, cpf_fmt = gen_cpf()
    plate = gen_plate()
    cust = http("POST", "/customers", {
        "documentType": "CPF", "documentNumber": cpf_fmt,
        "name": "João da Silva", "email": "joao@example.com", "phone": "11977776666"})
    http("POST", "/vehicles", {
        "customerId": cust["id"], "plate": plate, "brand": "Fiat",
        "model": "Argo", "year": 2022, "color": "Prata", "mileageKm": 33000})
    ok(f"Customer + Vehicle ({plate})")

    step("4/6", "Abre OS pedindo MAIS do que existe (qty=10, stock=5)")
    order = http("POST", "/orders", {
        "customerCpf": cpf_raw, "customerName": "João da Silva",
        "customerPhone": "11977776666", "vehiclePlate": plate,
        "vehicleBrand": "Fiat", "vehicleModel": "Argo", "vehicleYear": 2022})
    order_id = order["id"]
    http("PATCH", f"/orders/{order_id}/status",
         {"status": "DIAGNOSIS", "changedBy": "api"})
    http("POST", f"/orders/{order_id}/items", {
        "itemType": "PART", "catalogItemId": part_id, "name": "Disco",
        "unitPrice": 320.00, "quantity": 10})
    http("POST", f"/orders/{order_id}/budget", {"discount": 0, "validDays": 7})
    ok(f"Order {order_id} criada (espera-se falha na reserva)")

    step("5/6", "Aprova budget → SAGA tenta reservar")
    http("POST", f"/orders/{order_id}/budget/approve")
    arrow("order publica order.budget.approved")
    arrow("saga publica stock.reserve-stock")
    arrow("catalog: estoque insuficiente → publica stock.stock-insufficient")
    arrow("saga grava RESERVATION_FAILED + chama POST /orders/:id/cancel")
    time.sleep(5)
    logs_since("saga-orchestrator", 10, grep="reserve|insufficient|cancel")
    logs_since("catalog-service", 10, grep="insufficient|reserve")
    logs_since("order-service", 10, grep="cancel")

    step("6/6", "Verifica estado final — saga FAILED, order CANCELLED, estoque intacto")
    saga_st = saga_status_of(order_id)
    saga_reason = saga_reason_of(order_id)
    order_curr = http("GET", f"/orders/{order_id}", show=False)
    stock = http("GET", f"/parts/{part_id}", show=False)
    section("DB state final")
    kv("saga_states.status:", saga_st)
    kv("saga_states.reason:", saga_reason[:120] + ("…" if len(saga_reason) > 120 else ""))
    kv("orders.status:", order_curr["status"])
    kv("part stock/reserved:",
       f"stock={stock['stockQuantity']} reserved={stock['reservedQuantity']}")

    assert saga_st == "RESERVATION_FAILED", f"saga deveria ser RESERVATION_FAILED, está {saga_st}"
    assert order_curr["status"] == "CANCELLED", f"order deveria ser CANCELLED, está {order_curr['status']}"
    assert stock["reservedQuantity"] == 0, "nenhum estoque deveria ficar reservado"
    ok("Compensation correta: saga falhou, order cancelada, estoque preservado")

    banner("✅ BAD PATH 1 COMPLETO — fluxo de compensação OK")


def scenario_bad_payment() -> None:
    banner("BAD PATH 2 — pagamento rejeitado → charge REJECTED, order não vira PAID")
    check_kong()

    step("1/8", "Admin loga + cria peça com estoque suficiente")
    http("POST", "/auth/login/admin",
         {"email": "admin@autoflow.com", "password": "Admin@123"}, show=False)
    part = http("POST", "/parts", {
        "name": "Filtro de Óleo Premium", "category": "FILTER", "unit": "UN",
        "stockQuantity": 50, "minimumStock": 5}, show=False)
    part_id = part["id"]
    ok(f"Part id={part_id} stock=50")

    step("2/8", "Cria cliente + veículo")
    cpf_raw, cpf_fmt = gen_cpf()
    plate = gen_plate()
    cust = http("POST", "/customers", {
        "documentType": "CPF", "documentNumber": cpf_fmt,
        "name": "Ana Beatriz", "email": "ana@example.com", "phone": "11955554444"},
        show=False)
    http("POST", "/vehicles", {
        "customerId": cust["id"], "plate": plate, "brand": "Honda",
        "model": "Civic", "year": 2024, "color": "Preto", "mileageKm": 5000},
        show=False)
    ok(f"Customer + Vehicle ({plate})")

    step("3/8", "Abre OS + budget (quantidade normal)")
    order = http("POST", "/orders", {
        "customerCpf": cpf_raw, "customerName": "Ana Beatriz",
        "customerPhone": "11955554444", "vehiclePlate": plate,
        "vehicleBrand": "Honda", "vehicleModel": "Civic", "vehicleYear": 2024},
        show=False)
    order_id = order["id"]
    http("PATCH", f"/orders/{order_id}/status",
         {"status": "DIAGNOSIS", "changedBy": "api"}, show=False)
    http("POST", f"/orders/{order_id}/items", {
        "itemType": "PART", "catalogItemId": part_id, "name": "Filtro",
        "unitPrice": 89.90, "quantity": 2}, show=False)
    http("POST", f"/orders/{order_id}/budget", {"discount": 0, "validDays": 7},
         show=False)
    ok(f"Order {order_id} pronta")

    step("4/8", "Aprova budget → saga reserva")
    http("POST", f"/orders/{order_id}/budget/approve", show=False)
    time.sleep(4)
    assert saga_status_of(order_id) == "RESERVED"
    ok("Saga RESERVED")

    step("5/8", "Conclui execução → consume + payment.requested")
    http("POST", f"/orders/{order_id}/execution/complete", show=False)
    time.sleep(4)
    charge = http("GET", f"/billing/charges/order/{order_id}")
    assert charge["status"] == "PENDING"
    mp_id = charge["checkoutUrl"].split("/")[-1]
    ok(f"Charge PENDING (MP id={mp_id})")

    step("6/8", "Customer REJEITA o pagamento no mock MP")
    arrow("POST /billing/mock/reject/:mp_id  (em vez de /approve)")
    http("POST", f"/billing/mock/reject/{mp_id}")

    step("7/8", "Webhook MP chega → payment-service processa como REJECTED")
    arrow("POST /billing/webhook/mercadopago → use-case process-webhook")
    arrow("charge.reject() → publica payment.events::payment.rejected")
    http("POST", "/billing/webhook/mercadopago",
         {"type": "payment", "action": "payment.updated", "data": {"id": mp_id}})
    time.sleep(4)
    logs_since("payment-service", 8, grep="rejected|webhook|MOCK")

    step("8/8", "Verifica estado final — charge REJECTED, order AINDA awaiting payment")
    charge = http("GET", f"/billing/charges/order/{order_id}", show=False)
    order_curr = http("GET", f"/orders/{order_id}", show=False)
    section("DB state final")
    kv("charges.status:", charge["status"])
    kv("orders.status:", order_curr["status"])

    assert charge["status"] == "REJECTED", f"charge deveria ser REJECTED, está {charge['status']}"
    assert order_curr["status"] != "PAID", f"order NÃO deveria estar PAID, está {order_curr['status']}"
    ok("Pagamento corretamente rejeitado; order continua aguardando")

    # Verifica que notificação de payment-rejected foi enviada
    q = (f"db.notifications.find({{orderId:'{order_id}'}},"
         f"{{template:1,channel:1,_id:0}}).toArray()"
         f".forEach(n => print(JSON.stringify(n)))")
    notif_log = kubectl_mongo("notification", q, "notification_admin", "notification_pass")
    notifs = [json.loads(l) for l in notif_log.split("\n") if l.startswith("{")]
    section("notification-service.notifications")
    if not notifs:
        warn("nenhuma notificação encontrada")
    for n in notifs:
        print(f"    {n['channel']:6s} {n['template']}")

    banner("✅ BAD PATH 2 COMPLETO — rejeição tratada sem promover order a PAID")


SCENARIOS = {
    "happy": scenario_happy,
    "bad-stock": scenario_bad_stock,
    "bad-payment": scenario_bad_payment,
}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("scenario", choices=SCENARIOS.keys())
    args = p.parse_args()
    try:
        SCENARIOS[args.scenario]()
        return 0
    except AssertionError as e:
        err(f"ASSERTION FAILED: {e}")
        return 2
    except Exception as e:
        err(f"unhandled error: {e!r}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
