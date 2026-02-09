# inoc-lab-project (lab-manager backend)

Backend simples para orquestrar topologias KVM/virsh com **API Node.js** + **CLI local**.
Este README serve como fonte de verdade para frontends (Laravel/Codex) e futuras manutencoes.

## Visao geral
- **Objetivo**: criar/iniciar/parar/destroir topologias de VMs multi-vendor em KVM.
- **Entradas principais**:
  - `catalog/` (vendors e imagens)
  - `topologies/` (topologias declarativas)
- **Saidas geradas**:
  - `vms/<topologyId>/` (overlays qcow2)
  - `state/<topologyId>.json` (estado e inventario)

## Estrutura do projeto
- `lab-manager/` -> codigo da API/CLI (Node.js)
- `lab-manager.sh` -> entrypoint principal do CLI
- `catalog/` -> vendors e imagens (JSON)
- `topologies/` -> topologias (JSON)
- `images/functional/` -> imagens homologadas (biblioteca)
- `images/candidates/` -> imagens candidatas (biblioteca)
- `vms/` -> overlays gerados (runtime)
- `state/` -> estado das topologias (runtime)
- `.env` -> configuracao de porta, TLS e API key

## Configuracao (.env)
Arquivo: `/opt/inoc-lab-project/.env`

```
PORT=3101
API_KEY=troque-esta-chave
LAB_ROOT=/opt/inoc-lab-project
BRIDGE_BACKEND=linux
INSTANCES_DIR=/opt/inoc-lab-project/instances
CONSOLE_PORT_MIN=20000
CONSOLE_PORT_MAX=29999
WEB_PORT_MIN=50000
WEB_PORT_MAX=59999
CONSOLE_HOST=127.0.0.1
CORS_ORIGIN=*
SSL_CERT=/etc/ssl/certs/inoc-lab-manager.crt
SSL_KEY=/etc/ssl/private/inoc-lab-manager.key
SSL_CA=/etc/ssl/certs/ca-bundle.crt
SSL_PASSPHRASE=
BIND_ADDR=0.0.0.0
```

Regras de porta da API:
1) Se iniciar `node src/server.js --port 4000`, usa 4000.
2) Senao, usa `PORT` do `.env`.
3) Se nao existir, usa **3101**.

TLS:
- Se `SSL_CERT` e `SSL_KEY` existirem, sobe em HTTPS.
- Se os arquivos nao existirem, cai para HTTP automaticamente.

`BRIDGE_BACKEND`:
- `linux` (padrao): Linux bridge
- `ovs`: Open vSwitch (requer `ovs-vsctl`)

`INSTANCES_DIR`:
- Pasta onde ficam as reservas de instancias (`instances/*.json`).
- Se nao definido, usa `LAB_ROOT/instances`.

`CONSOLE_PORT_MIN/MAX` e `WEB_PORT_MIN/MAX`:
- Definem o range de portas que o lab-manager reserva para instancias.
- Mesmo sem criar VMs, as portas ficam reservadas enquanto a instancia existir.

## Catalogos (JSON)
### Inicializacao automatica
Ao iniciar a API/CLI, se pastas ou arquivos nao existirem, o lab-manager cria:
- `catalog/`, `topologies/`, `vms/`, `state/`, `images/functional/`, `images/candidates/`
- `catalog/vendors.json` e `catalog/images.json`

Se o catalogo nao existir, o sistema tenta copiar do repo (`catalog/`). Se ainda nao houver, cria um modelo padrao.
Caso a imagem qcow2 nao exista no caminho indicado em `catalog/images.json`, a criacao falha indicando o path esperado.

### Vendors: `catalog/vendors.json`
Cada vendor define parametros padrao e como as interfaces serao planejadas.

Chaves suportadas (principais):
- `default_memory`, `default_vcpus`
- `hidden_nics`
- `nic_model`, `disk_bus`
- `mac_base` (MAC base para gerar sequencia deterministica)
- `mac_stride` (passo por node para evitar MAC duplicado entre VMs)
- `os_variant`, `machine`, `cpu`, `virt_type`
- `mgmt_bridge`, `mgmt_model`
- `link_nic_start`, `link_nic_max`, `link_nic_position`
- `link_label_map`, `link_label_prefix`, `link_label_offset`, `link_label_skip`
- `pci_slot_start` (slot PCI inicial para ordenar interfaces)
- `web_forward` (objeto com `host`, `host_port_base`, `guest_port`, `model`, `place_last`, `mac`, `mac_offset`, `pci_slot`)
- `smbios` (string ou array) -> passa via `--qemu-commandline -smbios` no virt-install
- `rtc_base` -> passa via `--qemu-commandline -rtc base=...`
- `qemu_uuid` -> passa via `--qemu-commandline -uuid <uuid>`
- `uuid` -> passa via `--uuid <uuid>` (UUID do dominio libvirt)
- `virt_install_args` (array) -> argumentos adicionais ao `virt-install`

**Precedencia de memoria/vcpu**:
1) `node.memory` / `node.vcpus` (na topologia)
2) `image.memory` / `image.vcpus`
3) `vendor.default_memory` / `vendor.default_vcpus`

### Imagens: `catalog/images.json`
Cada imagem aponta para um arquivo na biblioteca.

Exemplo:
```
{
  "huawei-ne40e-v800r011c00spc607b607": {
    "vendor": "huawei",
    "path": "images/functional/huawei/NE40E-V800R011C00SPC607B607.qcow2",
    "memory": 1024,
    "vcpus": 1
  }
}
```

## Topologias (JSON)
Arquivo em `topologies/`. Exemplo simples (R1<->R2<->R3):
```
{
  "id": "base-huawei-r1-r2-r3",
  "asn": 65001,
  "console_port_base": 20000,
  "mgmt_bridge": "virbr0",
  "nodes": [
    { "id": "r1", "image": "huawei-ne40e-v800r011c00spc607b607" },
    { "id": "r2", "image": "huawei-ne40e-v800r011c00spc607b607" },
    { "id": "r3", "image": "huawei-ne40e-v800r011c00spc607b607" }
  ],
  "links": [
    { "a": "r1", "b": "r2" },
    { "a": "r2", "b": "r3" }
  ]
}
```

Opcionalmente, escolha interfaces especificas por link:
```
{
  "links": [
    { "a": "r1", "b": "r2", "a_port": "e1", "b_port": "e2" }
  ]
}
```

Campos relevantes do `node`:
- `id` (obrigatorio)
- `image` (obrigatorio)
- `name` (opcional, sobrescreve o nome da VM)
- `memory`, `vcpus` (opcionais)
- `console_port` (opcional)

## Planejamento de interfaces e nomes
### Nome da VM
- Padrao: `LAB-${asn}-${node.id.toUpperCase()}`
- Se `node.name` existir, ele e usado.

### Porta de console
- Padrao: `console_port_base + indice + 1`
- Se ausente, usa base 20000.

### Slots de link (interfaces de dados)
- Para cada node, o planner cria `linkSlots`.
- Quantidade: `max(qtd_links_do_node, vendor.link_nic_max)`.
- Inicio do indice: `vendor.link_nic_start` (padrao 1).
- Posicao dos links:
  - `first`: links primeiro
  - `after_mgmt`: mgmt primeiro, depois links
  - outro valor: links no final

### Labels de link
O label e usado para exibicao e para selecionar a interface no JSON:
- `link_label_map`: array (ex: ["e1", "e2", ...])
- `link_label_prefix` + `link_label_offset` (ex: prefix `e` -> e1, e2...)
- `link_label_skip`: labels reservados (nao usaveis)

### Target (nome do tap)
- Target base: `${vmName}-e${slotIndex}`
- Encurtado para 15 caracteres via hash (funcao `shortName`).

### MAC deterministico
- Padrao: MAC e derivado de hash (`macFor`) e **deterministico** por `vmName` e `slot`.
- Quando `vendor.mac_base` e definido, a sequencia de MACs e gerada a partir desse base
  (ex: `mac_base` + 0, +1, +2...), garantindo MACs fixos como no QEMU “puro”.
- Para evitar MAC duplicado entre VMs do mesmo vendor, o planner aplica um **offset por node**:
  - `mac_stride` (se definido) ou
  - `link_nic_max + (web_forward ? 1 : 0)` como padrao.
- `web_forward.mac` e deslocado pelo mesmo offset quando `mac_base` esta ativo.
- Alternativamente, use `web_forward.mac_offset` para gerar o MAC do web a partir do `mac_base`.

### Ordem PCI (ens3..ens11)
- Quando `vendor.pci_slot_start` e definido, as interfaces sao forçadas a usar slots PCI
  sequenciais a partir desse valor (ex: `pci_slot_start=3` -> slots `0x03..`).
- `web_forward.pci_slot` permite fixar o slot da interface web (ex: `0x0b` -> `ens11`).
- Outros dispositivos que conflitem com esses slots sao realocados para slots livres.

### Regra especial (vendor linux + web)
- Para replicar exatamente o layout do QEMU manual:
  - `nic_model`: `e1000`
  - `mgmt_disabled`: `true` (evita `ens2`)
  - `mac_base`: `52:54:00:12:34:56` (gera `ens3..ens10`)
  - `pci_slot_start`: `3` (slots `0x03..0x0a`)
  - `web_forward.mac`: `52:54:00:12:34:5e`
  - `web_forward.pci_slot`: `11` (slot `0x0b`, vira `ens11`)

## Bridges
- Cada link cria uma bridge `lm-${asn}-${a}-${b}-${index}` (encurtada).
- `br-null` e usado para:
  - hidden nics
  - slots de link nao usados
  - mgmt extra quando necessario

`br-null` evita que interfaces “sobrem” sem bridge valida, e tambem e usado como bridge neutra para VMs quando nao ha link real.

## Fluxo de criacao
1) **create**
   - planeja topologia (`planTopology`)
   - cria bridges e `br-null` (se necessario)
   - cria overlays qcow2 em `vms/<topologyId>/`
   - define VMs com `virt-install`
   - grava estado em `state/<topologyId>.json`
2) **start**
   - `virsh start` em cada VM
3) **stop**
   - `virsh shutdown` em cada VM
4) **destroy**
   - `virsh destroy/undefine` + remove overlay
   - remove bridges se `cleanup_bridges=true`

## Estado (state)
Arquivo: `state/<topologyId>.json`
- `nodes[]` -> vmName, consolePort, interfaces
- `links[]` -> bridge + `a_iface` / `b_iface`

`GET /topologies/:id/status`:
- Usa `virsh domstate`
- Em backend `linux`, faz FDB por bridge para mapear `guest_mac` e `tap_mac`

## CLI local
```
/opt/inoc-lab-project/lab-manager.sh list
/opt/inoc-lab-project/lab-manager.sh create base-huawei-r1-r2-r3
/opt/inoc-lab-project/lab-manager.sh start base-huawei-r1-r2-r3
/opt/inoc-lab-project/lab-manager.sh status base-huawei-r1-r2-r3
/opt/inoc-lab-project/lab-manager.sh links base-huawei-r1-r2-r3
/opt/inoc-lab-project/lab-manager.sh export base-huawei-r1-r2-r3 --format md
/opt/inoc-lab-project/lab-manager.sh stop base-huawei-r1-r2-r3
/opt/inoc-lab-project/lab-manager.sh destroy base-huawei-r1-r2-r3
```

## API (para Laravel)
### Inicializacao
```
cd /opt/inoc-lab-project/lab-manager
npm install
node src/server.js
```

### Autenticacao
Header esperado:
- `X-API-Key: <API_KEY>`
- ou `Authorization: Bearer <API_KEY>`

Se `API_KEY` estiver vazio, a API aceita sem header.

### Rotas
- `GET /health`
- `GET /catalog` (vendors + images)
- `GET /topologies`
- `GET /topologies/:id`
- `POST /topologies` (cria/salva JSON)
- `PUT /topologies/:id` (atualiza JSON)
- `POST /topologies/:id/create`
- `POST /topologies/:id/start`
- `POST /topologies/:id/stop`
- `POST /topologies/:id/restart`
- `GET /topologies/:id/status`
- `GET /topologies/:id/links`
- `GET /topologies/:id/interfaces`
- `GET /topologies/:id/export?format=csv|md`
- `GET /topologies/:id/state`
- `POST /topologies/:id/destroy` (body opcional: `{ "cleanup_bridges": true }`)

**Nodes**:
- `POST /topologies/:id/nodes/:nodeId/start`
- `POST /topologies/:id/nodes/:nodeId/stop`
- `POST /topologies/:id/nodes/:nodeId/restart`
- `POST /topologies/:id/nodes/:nodeId/destroy` (body opcional: `{ "remove_overlay": false }`)
- `POST /topologies/:id/nodes/:nodeId/recreate` (body opcional: `{ "start": true }`)

## Notas especificas (Nokia)
Requisitos comuns para SROS:
- `vendor.smbios` com TIMOS
- `vendor.rtc_base`
- `vendor.qemu_uuid` (UUID interno do QEMU)

Exemplo:
```
"nokia": {
  "default_memory": 6144,
  "default_vcpus": 2,
  "link_nic_start": 1,
  "link_nic_max": 10,
  "link_nic_position": "first",
  "nic_model": "virtio",
  "disk_bus": "virtio",
  "os_variant": "generic",
  "machine": "pc-i440fx-6.2",
  "cpu": "host",
  "mgmt_bridge": "virbr0",
  "mgmt_model": "virtio",
  "rtc_base": "2025-03-19T21:30:00",
  "qemu_uuid": "d0d7d7c5-cd69-4dd2-a8dc-3a0f7c8f52e6",
  "smbios": "type=1,product=TIMOS: slot=A card=cpm-1s chassis=sr-1s slot=1 card=xcm-1s mda/1=s18-100gb-qsfp28 system-base-mac=de:ad:be:ef:00:01 license-file=cf3:\\license.txt",
  "virt_install_args": [
    "--qemu-commandline=-global",
    "--qemu-commandline=ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
  ]
}
```

## Troubleshooting rapido
- **Cannot access storage file**: overlay nao foi criado ou path base incorreto.
- **Device or resource busy** (tap): interface ja existe; limpar taps antigos ou recriar node.
- **Exchange full** (br-null): muitos ports; reduza `link_nic_max` / `hidden_nics`.

---
Este README deve ser atualizado sempre que o comportamento do backend mudar (plan/virt-install/bridge/status).

## Checklist rapido para o Codex (ajustes futuros)
- Sempre revisar `lab-manager/src/lib/plan.js` antes de mexer em links/labels/slots.
- Regras de interfaces/labels:
  - quantidade de links = `max(links do node, vendor.link_nic_max)`
  - inicio em `vendor.link_nic_start`
  - label via `link_label_map` ou `link_label_prefix` + `link_label_offset`
  - `link_label_skip` reserva labels (nao usadas)
- `br-null` e criado quando existe interface de link/hidden sem bridge real.
- VM name default = `LAB-${asn}-${ID}`; usar `node.name` se existir.
- MACs sao deterministicas via `macFor(seed)` (plan.js).
- `virt-install` e chamado em `libvirt.defineVM()`; qualquer parametro extra precisa ser inserido ali.
- Nokia: precisa `rtc_base`, `qemu_uuid`, `smbios` e `virt_install_args` (ICH9-LPC hotplug off).
- Para status em tempo real, o endpoint confiavel e `GET /topologies/:id/status`.
