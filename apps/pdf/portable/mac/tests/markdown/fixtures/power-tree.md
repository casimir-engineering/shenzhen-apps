# Power tree — sample board (rev D)

Mirrors `power-tree.drawio` rev D (bare SOC-1 HVQFN ·
fingerprint 3.3 V_FP always-on BB-5 · no OTG) and the locked table in
`architecture-decisions.md`.

```mermaid
flowchart LR
  classDef aon fill:#e1f5ee,stroke:#0f6e56,color:#04342c
  classDef gated fill:#faeeda,stroke:#854f0b,color:#412402
  classDef src fill:#e6f1fb,stroke:#185fa5,color:#042c53
  classDef load fill:#f1efe8,stroke:#5f5e5a,color:#2c2c2a

  USB["USB-C VBUS<br/>5 V input"]:::src
  CHG["CHG-1 charger<br/>NVDC · VREG 4.208 V · SYS_MIN 3.5 V"]:::src
  BAT["1S Li-ion 1000 mAh<br/>standard 4.2 V cell"]:::src
  VSYS(["VSYS 3.5–4.26 V<br/>= VBAT + 50 mV"]):::src

  USB --> CHG
  CHG <--> BAT
  CHG --> VSYS

  U101["BUCK-1 buck<br/>360 nA IQ · R101"]:::aon
  AON(["1.8 V AON — always on"]):::aon
  VSYS --> U101 --> AON
  AON --> NRF["MCU-1 VDD"]:::load
  AON --> IMU["IMU-1 IMU"]:::load
  AON --> ALS["ALS-1 ALS+prox"]:::load
  AON --> KEYS["Keys"]:::load

  U102["BB-2 buck-boost 2 A<br/>R102"]:::gated
  RW33(["3.3 V_RW — on in Wi-Fi coverage,<br/>nRF-gated otherwise"]):::gated
  VSYS --> U102 --> RW33
  RW33 --> RWPWR["SOC-1 VBAT + VPA + AVDD33_USB<br/>(1.05 V core + 1.8 V analog are<br/>chip-internal bucks via 2 inductors)"]:::load
  U103["LDO-class LDO"]:::gated
  RW18(["1.8 V_RW — follows 3.3 V_RW<br/>(sequencing safe)"]):::gated
  RW33 --> U103 --> RW18
  RW18 --> RWVIO["SOC-1 VIO_1–6 + VIO_RF"]:::load
  RW18 --> NOR["NOR-1 FlexSPI NOR"]:::load
  PMOS["PMOS switch<br/>VBUS_CTRL GPIO"]:::gated
  RW33 --> PMOS --> VBUSDET["MODEM-1 USB_VBUS pin<br/>detect input only (3.0–5.25 V)<br/>assert = attach USB, deassert = modem sleep"]:::load

  U104["LDO-4 LDO<br/>R104 · gated"]:::gated
  LN(["1.8 V_LN — on during capture"]):::gated
  VSYS --> U104 --> LN
  LN --> MICS["PDM mics<br/>MIC-1 (face B) + top-port TBD"]:::load

  U105["BB-5 buck-boost<br/>75 nA IQ · R105"]:::aon
  FP(["3.3 V_FP — always on<br/>(touch-wake)"]):::aon
  VSYS --> U105 --> FP
  FP --> FPMOD["Fingerprint flex module<br/>(FPC J601)"]:::load

  SW["LSW-6 load switch 3 A<br/>R106 · FW lockout &lt; 3.4 V"]:::gated
  LTE(["LTE_VBAT — gated"]):::gated
  BAT --> SW --> LTE
  LTE --> MODEM["MODEM-1 Cat 1bis<br/>+ eSIM-1 eSIM (1.8 V ISO 7816)"]:::load

  VSYS --> AMP["AMP-1 amp (EN)"]:::load
  VSYS --> HAP["HAPTIC-1 + LRA (EN)"]:::load
  VSYS --> LED["LEDs (FET-1 low-side)"]:::load
  VSYS --> VDDH["MCU-1 VDDH"]:::load
```

**Legend:** green = always-on · amber = gated/conditional · blue = source path
· gray = load.

Notes (from the locked table):

- **SOC-1 supplies only** VBAT/VPA/AVDD33_USB (3.3 V) and VIO pads (1.8 V);
  AVDD18/VCORE come from the chip's internal bucks through two mandatory
  external inductors. Sequencing: VBAT/VPA no later than any rail, PDn held
  low until stable — satisfied by construction since 1.8 V_RW derives from
  3.3 V_RW.
- **LTE hangs off the BAT node** through the load switch; VREG = 4.208 V
  keeps the node under the module's 4.3 V absolute max (standard 4.2 V cell
  mandatory, no 4.35/4.4 V cell).
- **No OTG / no 5 V boost** — MODEM-1 USB_VBUS is a detect input; the PMOS
  from 3.3 V_RW drives it for USB attach/detach control.
- Reset supervision: custom discrete circuit (SUP-1 dropped).
