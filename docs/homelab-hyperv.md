# Homelab trên Hyper-V: cụm Kubernetes (kubeadm) cho commerce-hub

Hướng dẫn biến máy bàn Windows thành "hạ tầng server" gồm nhiều VM Debian 12, chạy cụm Kubernetes dựng bằng kubeadm (kèm Kafka, PostgreSQL, Redis, OpenSearch chạy trong cụm), truy cập từ MacBook qua Tailscale. Windows vẫn dùng bình thường song song.

**Máy:** Intel Core i9-10900 (10 nhân / 20 luồng), 32 GB RAM, SSD 500 GB, Windows 10 Pro (bản 1909, build 18363). Hyper-V đã bật theo mục 1.3.

**Thời gian dựng lần đầu:** khoảng một ngày (mục 7 dựng cụm bằng kubeadm chiếm khoảng nửa ngày).

> **Độ tin cậy.** Các lệnh và thông số được tra từ tài liệu chính thức của Microsoft, Debian, systemd, Tailscale, Kubernetes, containerd, Docker, Calico, MetalLB, local-path-provisioner và metrics-server vào tháng 11/2026 (danh sách ở cuối). Mục 8.6–8.9 (cửa vào cụm, DNS, CA, Mailpit) tóm từ chuẩn [cluster-entry.md](../../docs/standards/cluster-entry.md), nguồn chi tiết ở đó. Chỗ nào tài liệu không xác nhận trực tiếp thì ghi **(chưa xác minh)** và kèm cách kiểm tra hoặc phương án thay thế.

---

## 0. Tổng quan

### Kiến trúc

```
MacBook ── Tailscale ──┐
                       │ (WireGuard; chỉ đi ra ngoài, không mở port nào ở nhà)
                       ▼
Máy bàn: Windows 10 Pro + Hyper-V
  │
  ├─ vSwitch "LabNAT" (Internal + WinNAT)  ── mạng riêng 10.20.0.0/24, gateway 10.20.0.1 = Windows
  │     │
  │     ├─ gw       10.20.0.5   Tailscale subnet router + registry image (cổng 5000)
  │     │                       + dnsmasq cho lab.internal (cổng 53) + Mailpit (SMTP 1025, UI 8025)
  │     ├─ k8s-cp   10.20.0.10  control plane (etcd, apiserver, scheduler, controller-manager) + nhận pod
  │     ├─ k8s-w1   10.20.0.11  worker
  │     └─ k8s-w2   10.20.0.12  worker
  │           │
  │           └─ trên cả 3 node: service commerce-hub + Kafka (3 broker), PostgreSQL, Redis, OpenSearch
  │
  └─ 10.20.0.200–250: dải IP LoadBalancer do MetalLB cấp
        10.20.0.200 cố định cho Gateway edge (Envoy Gateway): mọi *.lab.internal đi vào đây

Mạng trong cụm: pod 10.244.0.0/16 (Calico), service 10.96.0.0/12 (mặc định của kubeadm)
```

### Vì sao chọn như vậy

| Quyết định | Lý do |
|---|---|
| **Internal switch + NAT**, không dùng External switch | Mạng lab có dải IP riêng, cố định, không phụ thuộc router nhà, và vẫn chạy khi máy bàn dùng Wi-Fi. "Default Switch" của Hyper-V cũng là NAT nhưng đổi IP sau mỗi lần khởi động lại; tự tạo NAT thì giữ được IP tĩnh |
| **Tailscale subnet router chạy trên VM Linux (`gw`)**, không chạy trên Windows | Trên Windows, Tailscale định tuyến ở chế độ userspace: chỉ chuyển tiếp TCP, UDP và ping. Trên Linux là routing đầy đủ ở kernel. Dùng một VM nhỏ riêng để khi khởi động lại VM khác thì vẫn vào được lab |
| **Debian 12 (bookworm)** | Chủ dự án chọn. Microsoft liệt kê Debian 12 trong danh sách Linux được hỗ trợ trên Hyper-V, có boot UEFI (Gen 2) và Secure Boot. Bảng đó chỉ ghi host Windows Server 2016 trở lên, không nhắc Windows 10 1909 (chưa xác minh trên host này). Debian 12 đã sang giai đoạn LTS, nhận bản vá tới 30/06/2028. Kernel 6.1 |
| **kubeadm** (Kubernetes gốc), không dùng k3s | Mục tiêu là học và đi phỏng vấn: thấy rõ từng thành phần control plane (static pod), tự backup etcd, tự chọn CNI, tự nâng cấp cụm và xoay vòng certificate. Đây cũng là cách bài thi CKA dựng cụm. Đổi lại tốn thêm khoảng 1–2 GB RAM và nửa ngày dựng |
| **Calico** làm CNI | Phổ biến, có NetworkPolicy, nhẹ hơn Cilium, hợp với cụm đang sát RAM. Cilium để dành khi nâng máy lên 64 GB |
| **Hạ tầng dữ liệu chạy trong cụm bằng operator** (Strimzi, CloudNativePG), không có VM `data` riêng | Kafka chạy đủ 3 broker trên 3 node (replication factor 3), Postgres có primary và replica tự failover. Học được StatefulSet, PersistentVolume, anti-affinity, PodDisruptionBudget. Đổi lại: ổ đĩa gắn với node (`local-path`), làm hỏng cụm là mất luôn dữ liệu, drain node phải tính tới tầng dữ liệu |
| **Registry image trên `gw`**, ngoài cụm | Cụm hỏng vẫn kéo được image để dựng lại. Registry rất nhẹ nên ghép vào `gw` thay vì tạo thêm VM |
| **Control plane cũng nhận pod** | Chỉ có 3 node, nên gỡ taint mặc định của kubeadm để Kafka/Postgres trải đều cả 3 node. Production thật không làm vậy |

### Chia tài nguyên (32 GB RAM, 20 luồng)

| VM | vCPU | RAM | Ổ ảo (dynamic, tối đa) | Vai trò |
|---|---|---|---|---|
| Windows (host) | — | ~6 GB | — | Hệ điều hành, ứng dụng hằng ngày |
| gw | 1 | 2 GB | 100 GB | Tailscale subnet router, registry image, dnsmasq (`lab.internal`), Mailpit |
| k8s-cp | 4 | 8 GB | 100 GB | Control plane + workload |
| k8s-w1 | 6 | 8 GB | 100 GB | Worker |
| k8s-w2 | 6 | 8 GB | 100 GB | Worker |
| **Tổng VM** | **17** | **26 GB** | | |

**Ước lượng RAM trên 3 node (24 GiB), Giai đoạn 0–1:** chốt ở [ticket 04 của docs](../../docs/.scratch/architecture-g0-g1/issues/04-resource-budget.md#answer) và [ADR-0004](../../docs/adr/0004-single-instance-by-default-on-homelab.md). Mặc định mỗi service và database **1 instance**; thí nghiệm cần thì mới scale lên.

| Thành phần | RAM |
|---|---|
| Hệ điều hành, kubelet, containerd (×3 node) | ~2,4 GB |
| Control plane, CoreDNS, kube-proxy, Calico, MetalLB, metrics-server, local-path | ~3,1 GB |
| Argo CD, Sealed Secrets, cert-manager, Strimzi Drain Cleaner | ~1,3 GB |
| Kafka 3 broker (1 Gi mỗi broker) + Strimzi operator, Entity Operator | ~3,9 GB |
| Apicurio Registry | ~0,9 GB |
| PostgreSQL `pg-main` 1 instance + Pooler + Barman + CNPG | ~1,5 GB |
| Keycloak 1 instance + operator | ~2 GB |
| LGTM (Prometheus, Loki, Tempo, Grafana, Collector…) | ~3,4 GB |
| Service G1 (6 service, shopee-sim, frontend, 1 replica; surge, Job Flyway) | ~4,6 GB |
| Envoy Gateway (controller 256 Mi, Envoy 1 replica 128 Mi, shutdown-manager 32 Mi) + trust-manager 64 Mi ([ADR-0013](../../docs/adr/0013-gateway-api-envoy-gateway-shared-edge.md)) | ~480 MiB |
| **Còn dư** | **~520 MiB** |

Redis (Giai đoạn 3) và OpenSearch (Giai đoạn 6) chưa có trong bảng: tới giai đoạn đó phải tính lại. dnsmasq và Mailpit chạy trên `gw` nên không tính vào bảng này. Dòng Envoy Gateway là limit đặt tay theo benchmark của bản v1.10.0, phải đo lại ở G0.

Đây là ước lượng cho lab, không phải số đo. OpenSearch nên chỉ bật khi cần. Đổi RAM của VM rất dễ: `Stop-VM`, `Set-VMMemory -VMName <vm> -StartupBytes 10GB`, `Start-VM`.

- vCPU được phép cấp vượt số luồng thật. Hyper-V chia thời gian CPU giữa các VM.
- **RAM cấp cố định, tắt Dynamic Memory.** Nếu RAM của node co giãn, kubelet và scheduler tính sai tài nguyên.
- VM nằm ở ổ `D:` (còn khoảng 100 GB trống lúc dựng lab). Ổ dynamic chỉ chiếm dung lượng thực đã dùng, nhưng tổng tối đa của 4 VM là 400 GB, lớn hơn nhiều so với chỗ trống. Theo dõi dung lượng trống (mục 10). Nên lắp thêm một SSD 1 TB khi có điều kiện.
- Cần chạy nhiều hơn (OpenSearch, ClickHouse): i9-10900 hỗ trợ tới 128 GB RAM. Nâng lên 64 GB là khoản đầu tư hiệu quả nhất cho lab này.

---

## 1. Chuẩn bị Windows

### 1.1 Lên Windows 11 trước (khuyến nghị, không bắt buộc)

> **Ở lại Windows 10 vẫn làm được toàn bộ hướng dẫn này.** Hyper-V, các lệnh PowerShell, `ssh`, Remote Desktop và Tailscale trên Windows 10 Pro for Workstations dùng y hệt. Lý do nâng cấp là **bản vá bảo mật**, không phải tính năng. Nếu ở lại Windows 10, làm theo **Phụ lục A** ở cuối tài liệu: lên 22H2, đăng ký ESU, chặn Windows kết nối tới Mac bằng Tailscale ACL, làm cứng Windows, chuẩn bị nâng cấp.

**Windows 10 đã hết hỗ trợ từ 14/10/2025** và không còn bản vá bảo mật, trừ khi đăng ký ESU. ESU cho người dùng cá nhân kéo dài tới 12/10/2027, nhưng chưa rõ có áp dụng cho bản Pro for Workstations hay không (chưa xác minh). Máy này sắp chạy server 24/7 và nối vào tailnet, nên hãy nâng cấp:

- **i9-10900 nằm trong danh sách CPU được Windows 11 hỗ trợ** (dòng Core i9 thế hệ 10).
- Có bản **Windows 11 Pro for Workstations**. Phiên bản mới nhất hiện tại là **26H2** (build 26300), hỗ trợ tới 10/10/2028. 24H2 đã hết cập nhật.

Các bước:

1. **Sao lưu dữ liệu quan trọng** ra ổ ngoài hoặc cloud.
2. Kiểm tra điều kiện bằng ứng dụng **PC Health Check**, hoặc:
   - `Win + R` → `tpm.msc`: dòng *Specification Version* phải là **2.0**. Nếu báo "Compatible TPM cannot be found" thì vào BIOS bật **Intel PTT (Platform Trust Technology)**. Nếu máy có BitLocker, ghi lại recovery key trước, và **không bấm Clear TPM**.
   - `Win + R` → `msinfo32`: *BIOS Mode* = **UEFI**, *Secure Boot State* = **On** (chưa xác minh trên tài liệu chính thức, nhưng là cách kiểm tra phổ biến). Nếu Secure Boot đang Off thì bật trong BIOS. Nếu BIOS Mode là Legacy thì cần chuyển ổ sang GPT (`mbr2gpt`) trước, việc này rủi ro hơn, hãy hỏi lại trước khi làm.
3. **Settings → Windows Update**: nếu có lời mời nâng cấp lên Windows 11 thì cài theo hướng dẫn. Microsoft chỉ xác nhận rõ việc nâng cấp miễn phí và giữ dữ liệu cho Home/Pro; với Pro for Workstations nâng cấp tại chỗ thường cũng giữ file và ứng dụng (chưa xác minh), vì vậy bước 1 là bắt buộc.

### 1.2 BIOS

Vào BIOS (thường nhấn `Del` khi khởi động) và kiểm tra:

- **Intel Virtualization Technology (VT-x): Enabled.** Bắt buộc cho Hyper-V. VT-d không bắt buộc.
- **Intel PTT, Secure Boot**: như mục 1.1.
- Nếu có tùy chọn **Restore on AC Power Loss → Power On**, hãy bật. Máy sẽ tự khởi động lại khi có điện trở lại sau khi mất điện.

### 1.3 Bật Hyper-V

Mở **Terminal (Admin)** (`Win + X`):

```powershell
# Kiểm tra phần cứng: mục "Hyper-V Requirements" phải toàn "Yes"
# (nếu Hyper-V đã bật sẵn thì sẽ thấy dòng "A hypervisor has been detected")
systeminfo | Select-String "Hyper-V" -Context 0,4

# Bật Hyper-V và các công cụ quản lý, rồi khởi động lại máy
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

### 1.4 Giữ máy chạy 24/7

**Không cho máy ngủ.** Khi máy ngủ, mọi VM bị đóng băng và đồng hồ trong VM lệch.

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off
powercfg /change monitor-timeout-ac 15   # màn hình vẫn được tắt sau 15 phút
```

**Không cho Windows Update tự cài và tự khởi động lại.** Đặt chế độ "tự tải về, báo để người dùng cài" (`AUOptions = 3`). Windows chỉ tải cập nhật về, việc cài và khởi động lại do bạn chủ động làm mỗi tháng (xem 10.2):

```powershell
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 0 -Type DWord
Set-ItemProperty -Path $au -Name AUOptions    -Value 3 -Type DWord
```

Cách làm tương đương bằng giao diện: `gpedit.msc` → *Computer Configuration → Administrative Templates → Windows Components → Windows Update → Manage end user experience → Configure Automatic Updates* → **Enabled**, chọn **3 – Auto download and notify for install**.

Lưu ý:

- Policy "No auto-restart with logged on users" chỉ có tác dụng khi chọn chế độ 4, và chính Microsoft ghi nhận nó "không hoạt động đúng như mô tả". Vì vậy dùng chế độ 3.
- Thêm một lớp an toàn: **Settings → Windows Update → Advanced options → Active hours** đặt thủ công tối đa 18 giờ (ví dụ 06:00–24:00).
- Trường hợp vẫn bị khởi động lại ngoài ý muốn, các VM sẽ tự tắt an toàn và tự bật lại (cấu hình ở mục 4).

### 1.5 Quản lý Windows từ Mac

- Bật **Remote Desktop**: Settings → System → Remote Desktop → On.
- Cài **Tailscale cho Windows** và đăng nhập cùng tài khoản với Mac. Đây là client bình thường, không làm subnet router. Từ Mac dùng ứng dụng *Windows App* (tên mới của Microsoft Remote Desktop) để kết nối tới tên máy hoặc IP Tailscale của Windows.

---

## 2. Mạng lab: Internal switch + NAT

```powershell
# WinNAT chỉ cho phép MỘT mạng NAT trên mỗi máy. Lệnh này phải không trả về gì.
# Nếu đã có (do Docker Desktop hoặc thử nghiệm cũ), dừng lại và kiểm tra trước khi tạo thêm.
Get-NetNat

# 1. Switch nội bộ
New-VMSwitch -SwitchName 'LabNAT' -SwitchType Internal

# 2. Gán IP gateway cho card ảo phía Windows
$if = Get-NetAdapter -Name 'vEthernet (LabNAT)'
New-NetIPAddress -IPAddress 10.20.0.1 -PrefixLength 24 -InterfaceIndex $if.ifIndex

# 3. NAT cho cả dải
New-NetNat -Name 'LabNAT' -InternalIPInterfaceAddressPrefix 10.20.0.0/24

# Kiểm tra
Get-NetNat; Get-NetIPAddress -IPAddress 10.20.0.1
```

- WinNAT **không có DHCP**, nên mỗi VM tự đặt IP, gateway (`10.20.0.1`) và DNS. Đây cũng chính là điều mình muốn: IP cố định.
- Chọn dải `10.20.0.0/24` để tránh trùng với dải mạng nhà thường gặp (`192.168.x.x`) và dải của Tailscale (`100.64.0.0/10`). Nếu mạng nhà hay mạng công ty của bạn đã dùng `10.20.0.0/24` thì đổi sang dải khác, và đổi đồng loạt mọi IP trong tài liệu này.

### Bảng IP

| IP | Máy |
|---|---|
| 10.20.0.1 | Windows (gateway) |
| 10.20.0.5 | gw |
| 10.20.0.10 | k8s-cp |
| 10.20.0.11 – .12 | k8s-w1, k8s-w2 (dành .13–.19 cho node sau này) |
| 10.20.0.99 | IP tạm của golden image |
| 10.20.0.200 – .250 | MetalLB |

---

## 3. Golden image: cài Debian một lần, nhân bản nhiều lần

Ý tưởng: cài và cấu hình kỹ một VM Debian (golden), tắt đi, rồi copy file ổ đĩa của nó cho các VM khác. Nhanh hơn cài 4 lần, và mọi node giống hệt nhau.

### 3.1 Hàm tạo VM (dùng cho cả golden và các VM sau)

Tải ISO **Debian 12 netinst (amd64)** từ debian.org (trang *Download* → *Other releases* hoặc thư mục `cdimage.debian.org/cdimage/archive/` nếu trang chủ chỉ còn bản 13), tên dạng `debian-12.x.0-amd64-netinst.iso`, khoảng 650 MB. Lab này để mọi thứ trong `D:\Study\lab\`: ISO ở `D:\Study\lab\ISO\`, VM ở `D:\Study\lab\HyperV\`. Thư mục VM nên nằm trên SSD.

Dán đoạn này vào Terminal (Admin). Hàm chỉ tồn tại trong cửa sổ hiện tại; mở cửa sổ mới thì dán lại.

```powershell
$VmRoot = 'D:\Study\lab\HyperV'
$Switch = 'LabNAT'

function New-LabVM {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Cpu = 2,
        [int]$MemGB = 2,
        [string]$FromVhdx,          # copy từ golden; bỏ trống thì tạo ổ mới
        [int]$DiskGB = 100,
        [string]$Iso                # gắn ISO để cài (chỉ dùng cho golden)
    )
    $dir  = Join-Path $VmRoot $Name
    $vhdx = Join-Path $dir "$Name.vhdx"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if ($FromVhdx) { Copy-Item $FromVhdx $vhdx }
    else { New-VHD -Path $vhdx -SizeBytes ($DiskGB * 1GB) -Dynamic -BlockSizeBytes 1MB | Out-Null }

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($MemGB * 1GB) `
           -VHDPath $vhdx -SwitchName $Switch -Path $VmRoot | Out-Null
    Set-VMMemory    -VMName $Name -DynamicMemoryEnabled $false
    Set-VMProcessor -VMName $Name -Count $Cpu
    Set-VMFirmware  -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -CheckpointType Production `
           -AutomaticStartAction Start -AutomaticStopAction ShutDown

    if ($Iso) {
        Add-VMDvdDrive -VMName $Name -Path $Iso
        Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMDvdDrive -VMName $Name)
    }
    Get-VM -Name $Name
}
```

Giải thích các lựa chọn:

- **Generation 2**: dùng UEFI, hiệu năng tốt hơn Gen 1, Microsoft ghi Debian 12 hỗ trợ boot UEFI và Secure Boot.
- **`-BlockSizeBytes 1MB`**: Microsoft khuyến nghị cho VHDX dynamic chạy Linux. Mặc định 32 MB làm file phình to hơn mức cần.
- **`MicrosoftUEFICertificateAuthority`**: template Secure Boot cho Linux. Template mặc định chỉ chấp nhận Windows nên Debian sẽ không boot được (Debian boot qua `shim` do Microsoft UEFI CA ký). Tên này được dùng rộng rãi nhưng trang tài liệu cmdlet không liệt kê (chưa xác minh). Nếu báo lỗi, đổi thành `-EnableSecureBoot Off`.
- **`AutomaticCheckpointsEnabled $false`**: Hyper-V trên Windows mặc định tự tạo checkpoint mỗi lần bật VM, vừa tốn ổ vừa không cần thiết.
- **`AutomaticStopAction ShutDown`**: khi Windows tắt hoặc khởi động lại, VM được tắt đúng cách (gửi lệnh shutdown vào Debian), không bị "rút điện".

### 3.2 Tạo và cài golden

```powershell
New-LabVM -Name 'debian-golden' -Cpu 2 -MemGB 4 -DiskGB 100 -Iso 'D:\Study\lab\ISO\debian-12.12.0-amd64-netinst.iso'
Start-VM 'debian-golden'
vmconnect.exe localhost 'debian-golden'
```

Đổi tên file ISO cho đúng bản đã tải. Nếu VM báo "Secure Boot violation" hoặc không vào được menu cài đặt, chạy `Set-VMFirmware debian-golden -EnableSecureBoot Off` rồi `Restart-VM debian-golden -Force`.

Trong trình cài đặt Debian (dùng phím mũi tên, `Space` để tích, `Tab` để nhảy tới nút, `Enter` để chọn):

1. Menu đầu tiên: chọn **Install** (bản chữ, nhẹ và dễ thao tác trong cửa sổ vmconnect hơn *Graphical install*).
2. Language `English`, Location theo ý (ví dụ *other → Asia → Vietnam*), locale `en_US.UTF-8`, Keyboard `American English`.
3. **Network**: mạng `LabNAT` không có DHCP nên bộ cài sẽ báo *Network autoconfiguration failed*. Bấm Continue → chọn **Configure network manually**:
   - IP address `10.20.0.99/24` (có thể nhập kèm `/24`, khi đó bộ cài không hỏi netmask; nếu nó vẫn hỏi thì nhập `255.255.255.0`)
   - Gateway `10.20.0.1`
   - Name server addresses `1.1.1.1 8.8.8.8` (cách nhau bằng dấu cách)
   - Hostname `debian-golden`, Domain name để trống
4. **Root password: để trống cả hai lần.** Khi đó tài khoản root bị khóa, bộ cài sẽ cài `sudo` và cho user đầu tiên dùng `sudo`. Đặt mật khẩu root thì `sudo` không được cài, các lệnh trong tài liệu sẽ không chạy.
5. User: full name `lab`, username `lab`, đặt mật khẩu. Múi giờ chọn theo ý.
6. **Partition disks**:
   - Chọn **Guided - use entire disk** (không chọn bản có LVM) → chọn ổ `Msft Virtual Disk` 100 GB → **All files in one partition**.
   - Ở màn hình tổng quan, chọn dòng phân vùng **swap** → **Delete the partition**. Kubernetes cần máy không có swap; xóa ngay lúc cài gọn hơn tắt sau. Phần trống vài GB ở cuối ổ bỏ đi cũng không sao.
   - **Finish partitioning and write changes to disk**. Bộ cài hỏi có muốn quay lại tạo swap không → **No**. Hỏi ghi thay đổi ra ổ → **Yes**.
7. Package manager: *Scan extra installation media* → **No**. Mirror: chọn quốc gia gần, rồi `deb.debian.org`. HTTP proxy để trống.
8. Popularity contest: **No**.
9. **Software selection**: bỏ tích *Debian desktop environment* và *GNOME*; chỉ tích **SSH server** và **standard system utilities**.
10. *Force GRUB installation to the EFI removable media path* → **Yes**. Bắt buộc với VM sẽ nhân bản: bộ cài chỉ ghi mục khởi động vào NVRAM của chính VM golden; VM nhân bản có NVRAM trống nên chỉ boot được qua đường dẫn dự phòng `EFI\BOOT\BOOTX64.EFI`, mà đường dẫn này chỉ có khi chọn Yes. Chọn No thì bản sao báo *The boot loader did not load an operating system*. Nếu bộ cài không hỏi câu này, làm thêm bước "Bật đường dẫn EFI dự phòng" ở đầu mục 3.3.
11. *Installation complete* → Continue. VM khởi động lại, nhưng vì ổ DVD vẫn đứng đầu thứ tự boot nên sẽ vào lại menu cài đặt. Thấy menu đó thì làm bước dưới.

Bộ cài Debian không có bước nhập SSH key; key của Mac sẽ được thêm ở mục 3.3.

Gỡ ISO để VM boot từ ổ đĩa:

```powershell
Stop-VM 'debian-golden' -TurnOff -ErrorAction SilentlyContinue   # VM đang ở menu bộ cài nên tắt thẳng
Get-VMDvdDrive -VMName 'debian-golden' | Remove-VMDvdDrive
Start-VM 'debian-golden'
```

### 3.3 Cấu hình golden

Windows 10 từ bản 1803 có sẵn lệnh `ssh` (OpenSSH Client). Kiểm tra bằng `ssh -V` trong PowerShell; nếu báo không có lệnh thì cài bằng `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` (PowerShell Admin). Sau đó chạy `ssh lab@10.20.0.99`, rồi trong VM:

**Bật đường dẫn EFI dự phòng** (để VM nhân bản boot được; không hại gì nếu đã chọn Yes ở bước 10):

```bash
echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive grub-efi-amd64
ls /boot/efi/EFI/BOOT/        # phải có BOOTX64.EFI
```

```bash
# Kiểm tra mạng ra internet qua NAT
ping -c 2 1.1.1.1 && ping -c 2 debian.org

# Cập nhật và cài công cụ cơ bản (cài chrony sẽ tự gỡ systemd-timesyncd)
# hyperv-daemons: dịch vụ KVP/VSS/fcopy của Hyper-V; nhờ KVP mà Hyper-V Manager
# và `Get-VMNetworkAdapter` trên Windows hiện được IP của VM
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y chrony curl vim htop ethtool jq hyperv-daemons

# Đồng bộ giờ theo đồng hồ Hyper-V (PTP)
ls -l /dev/ptp_hyperv                       # phải tồn tại (rule udev có sẵn trong systemd 252 của Debian 12)
grep -r ptp_hyperv /etc/chrony/ || sudo tee /etc/chrony/conf.d/hyperv.conf >/dev/null <<'EOF'
refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0 stratum 2
makestep 1.0 -1
EOF
sudo systemctl restart chrony && chronyc sources

# Tắt swap (Kubernetes mặc định yêu cầu không có swap). Nếu đã xóa phân vùng swap
# lúc cài thì hai lệnh dưới không làm gì; để lại cho chắc. `swapon --show` phải trống.
sudo swapoff -a
sudo sed -i '/\sswap\s/d' /etc/fstab
swapon --show

# sudo không hỏi mật khẩu cho user lab (tiện cho Ansible sau này; chỉ hợp với lab)
echo 'lab ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/lab && sudo chmod 440 /etc/sudoers.d/lab
```

**Thêm SSH key của Mac.** Trên Mac chạy `cat ~/.ssh/id_ed25519.pub` (chưa có thì tạo bằng `ssh-keygen -t ed25519`), copy dòng kết quả, rồi trong VM:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA...dán-key-của-Mac... you@mac' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**Dịch vụ tự tạo SSH host key cho VM nhân bản.** Mỗi VM phải có host key riêng. Golden sẽ xóa key của nó; dịch vụ này tạo key mới ở lần boot đầu của từng bản sao:

```bash
sudo tee /etc/systemd/system/ssh-hostkeys.service >/dev/null <<'EOF'
[Unit]
Description=Tao SSH host key neu chua co (VM nhan ban tu golden)
Before=ssh.service ssh.socket
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable ssh-hostkeys.service
```

**Script đổi tên và IP cho VM nhân bản:**

```bash
sudo tee /usr/local/sbin/lab-init >/dev/null <<'EOF'
#!/usr/bin/env bash
# Dùng: sudo lab-init <hostname> <ip>   ví dụ: sudo lab-init k8s-cp 10.20.0.10
set -euo pipefail
name="$1"; ip="$2"
hostnamectl set-hostname "$name"
sed -i "s/debian-golden/${name}/g" /etc/hosts
sed -i "s/10\.20\.0\.99/${ip}/" /etc/network/interfaces
echo "Da doi thanh ${name} / ${ip}. Khoi dong lai..."
systemctl reboot
EOF
sudo chmod 755 /usr/local/sbin/lab-init
cat /etc/network/interfaces     # xác nhận có dòng "address 10.20.0.99/24" (hoặc address 10.20.0.99 + netmask)
```

**Dọn dẹp để golden thành "khuôn":**

```bash
sudo apt clean
sudo truncate -s 0 /etc/machine-id     # mỗi bản sao sẽ tự sinh machine-id mới khi boot
sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id   # D-Bus dùng chung id với systemd
sudo rm -f /etc/ssh/ssh_host_*         # mỗi bản sao sẽ tự sinh host key mới
sudo poweroff
```

`machine-id` phải khác nhau giữa các node, vì nhiều thành phần (systemd, một số plugin mạng) dựa vào nó để định danh máy.

Từ giờ **không bật lại `debian-golden`** (bật lên nó sẽ tự sinh machine-id và host key mới, không còn là khuôn sạch). Muốn cập nhật khuôn thì bật lên, cập nhật, rồi chạy lại phần dọn dẹp.

---

## 4. Tạo các VM từ golden

```powershell
$golden = 'D:\Study\lab\HyperV\debian-golden\debian-golden.vhdx'

New-LabVM -Name 'gw'     -Cpu 1 -MemGB 2 -FromVhdx $golden
New-LabVM -Name 'k8s-cp' -Cpu 4 -MemGB 8 -FromVhdx $golden
New-LabVM -Name 'k8s-w1' -Cpu 6 -MemGB 8 -FromVhdx $golden
New-LabVM -Name 'k8s-w2' -Cpu 6 -MemGB 8 -FromVhdx $golden

# Thứ tự bật khi Windows khởi động: gw → control plane → worker (đơn vị: giây)
Set-VM gw     -AutomaticStartDelay 0
Set-VM k8s-cp -AutomaticStartDelay 20
Set-VM k8s-w1 -AutomaticStartDelay 60
Set-VM k8s-w2 -AutomaticStartDelay 70

# Golden không tự bật
Set-VM debian-golden -AutomaticStartAction Nothing
```

**Đổi tên và IP từng VM, mỗi lần một máy.** Mọi bản sao lúc đầu đều mang IP `10.20.0.99`, nên phải đổi xong máy này mới bật máy kế tiếp:

```powershell
Start-VM gw
# đợi khoảng 30 giây
ssh-keygen -R 10.20.0.99                       # xóa host key cũ của .99 khỏi known_hosts
ssh -t lab@10.20.0.99 "sudo lab-init gw 10.20.0.5"
```

Lặp lại với từng máy:

| Bật VM | Lệnh |
|---|---|
| `k8s-cp` | `ssh -t lab@10.20.0.99 "sudo lab-init k8s-cp 10.20.0.10"` |
| `k8s-w1` | `ssh -t lab@10.20.0.99 "sudo lab-init k8s-w1 10.20.0.11"` |
| `k8s-w2` | `ssh -t lab@10.20.0.99 "sudo lab-init k8s-w2 10.20.0.12"` |

Trước mỗi lần nhớ chạy `ssh-keygen -R 10.20.0.99`.

Kiểm tra từ Windows:

```powershell
foreach ($ip in '10.20.0.5','10.20.0.10','10.20.0.11','10.20.0.12') {
  ssh -o StrictHostKeyChecking=accept-new lab@$ip "hostname; cat /etc/machine-id"
}
```

Mỗi máy phải có hostname đúng và **machine-id khác nhau**.

---

## 5. VM `gw`: Tailscale subnet router

SSH vào `lab@10.20.0.5`:

```bash
curl -fsSL https://tailscale.com/install.sh | sh

# Cho phép chuyển tiếp gói tin (bắt buộc với subnet router)
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

# Đăng nhập và quảng bá dải lab. Mở URL được in ra để đăng nhập.
sudo tailscale up --advertise-routes=10.20.0.0/24 --accept-dns=false   # giữ DNS 1.1.1.1/8.8.8.8 của lab, không để Tailscale ghi đè /etc/resolv.conf
```

**Bỏ qua bước tối ưu UDP.** Tailscale tăng thông lượng UDP khi chuyển tiếp nếu dùng Tailscale ≥ 1.54 **và kernel ≥ 6.2**. Debian 12 dùng kernel 6.1 nên không áp dụng. Với lab, `gw` vẫn chuyển tiếp đầy đủ, chỉ chậm hơn khi đẩy nhiều dữ liệu UDP.

<details>
<summary>Tùy chọn: dùng kernel mới từ bookworm-backports để bật tối ưu này</summary>

Microsoft cũng ghi rằng muốn có đủ tính năng kernel mới nhất trên Hyper-V thì dùng kernel từ kho backports của Debian.

```bash
echo 'deb http://deb.debian.org/debian bookworm-backports main' | sudo tee /etc/apt/sources.list.d/backports.list
sudo apt update && sudo apt install -y -t bookworm-backports linux-image-amd64
sudo reboot
# sau khi lên lại: uname -r phải ≥ 6.2
NETDEV=$(ip -o route get 8.8.8.8 | cut -f 5 -d " ")
sudo ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
```

Lệnh `ethtool` mất tác dụng sau khi khởi động lại. Tài liệu Tailscale chỉ hướng dẫn giữ lại bằng networkd-dispatcher hoặc NetworkManager, mà Debian cài kiểu server dùng ifupdown. Cách tương đương với ifupdown (chưa xác minh): thêm dòng sau vào khối `iface eth0` trong `/etc/network/interfaces`, thụt lề như các dòng khác:

```
	post-up /usr/sbin/ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off
```

</details>

Trong **trang quản trị Tailscale** (login.tailscale.com → Machines):

1. Máy `gw` có nhãn **Subnets**: mở menu `…` → **Edit route settings** → tick `10.20.0.0/24` → Save.
2. Menu `…` → **Disable key expiry**. Mặc định key hết hạn sau 180 ngày; với server thì tắt đi để không tự mất kết nối. Làm tương tự cho máy Windows.

**Trên MacBook:** cài Tailscale và đăng nhập cùng tài khoản. macOS tự nhận route của subnet router, không cần `--accept-routes` (cờ đó chỉ cần trên client Linux).

```bash
ping -c 2 10.20.0.10
ssh lab@10.20.0.10 hostname
```

Từ đây mọi thao tác đều làm từ Mac. Tiện nhất là khai báo các máy trong `~/.ssh/config` trên Mac:

```
Host gw k8s-cp k8s-w1 k8s-w2
  User lab
Host gw
  HostName 10.20.0.5
Host k8s-cp
  HostName 10.20.0.10
Host k8s-w1
  HostName 10.20.0.11
Host k8s-w2
  HostName 10.20.0.12
```

**Bảo mật:** không mở port nào trên router nhà. Tailscale chỉ tạo kết nối đi ra. Bật xác thực hai lớp cho tài khoản dùng đăng nhập Tailscale. Khi đã quen, dùng tag (`tag:homelab`) và ACL để giới hạn thiết bị nào được vào lab.

---

## 6. Registry image trên `gw`

Cụm chạy kiến trúc **amd64**, còn Mac M1 là **arm64**. Image build trên Mac phải nhắm `linux/amd64` (mục 9). Registry nằm trong lab để đẩy image lên nhanh, không phụ thuộc Docker Hub, và **nằm ngoài cụm** để cụm hỏng vẫn kéo được image về dựng lại.

Trên `gw` dùng gói `docker-registry` của Debian (phần mềm registry chính thức, chạy như một dịch vụ systemd), **không cài Docker**. Lý do: khi Docker bật chuyển tiếp gói tin, nó đặt policy của chain `FORWARD` thành `DROP`. Tài liệu Docker có ghi điều này, và nó dễ làm hỏng chức năng subnet router của Tailscale trên chính máy này.

**Gói này không có trong kho chính của Debian 12**, chỉ có trong **bookworm-backports** (bản 2.8.2). Thêm kho backports rồi cài:

```bash
ssh gw
grep -rq bookworm-backports /etc/apt/sources.list /etc/apt/sources.list.d/ \
  || echo 'deb http://deb.debian.org/debian bookworm-backports main' | sudo tee /etc/apt/sources.list.d/backports.list
sudo apt update
sudo apt install -y -t bookworm-backports docker-registry
```

**Thay file cấu hình mặc định.** File gói cài sẵn lấy từ file mẫu của dự án, trong đó bật xác thực `htpasswd` trỏ vào một thư mục chứ không phải file mật khẩu. Ghi đè bằng cấu hình gọn, không xác thực:

```bash
sudo cp /etc/docker/registry/config.yml /etc/docker/registry/config.yml.orig
sudo tee /etc/docker/registry/config.yml >/dev/null <<'EOF'
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/docker-registry
  delete:
    enabled: true          # cho phép xóa image (để dọn dung lượng)
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
sudo systemctl enable docker-registry
sudo systemctl restart docker-registry

systemctl is-active docker-registry              # active
ss -ltn | grep ':5000'                           # LISTEN ... *:5000
curl -s http://localhost:5000/v2/_catalog        # {"repositories":[]}
```

Kiểm tra từ Mac: `curl -s http://10.20.0.5:5000/v2/_catalog` cũng phải trả `{"repositories":[]}`.

- **Không có xác thực, không có TLS.** Chấp nhận được vì registry chỉ truy cập được từ mạng lab và từ tailnet của bạn. Đừng bao giờ mở cổng này ra internet.
- Image lưu ở `/var/lib/docker-registry` trên ổ của `gw`.
- Dọn image đã xóa để lấy lại dung lượng: `sudo -u docker-registry docker-registry garbage-collect /etc/docker/registry/config.yml`.
- Gói này là registry bản 2.8. Muốn bản 3.x thì chạy image `registry:3` bằng Docker hoặc Podman trên một VM khác, không chạy trên `gw`.

---

## 7. Cụm Kubernetes bằng kubeadm

Phiên bản được tra vào 11/2026: **Kubernetes 1.37** (bản stable là v1.37.2; dự án hỗ trợ 1.37, 1.36, 1.35), **Calico v3.33.0**, **MetalLB v0.16.2**, **local-path-provisioner v0.0.37**, **metrics-server v0.9.1**. containerd lấy từ kho apt của Docker (gói `containerd.io`, có kèm `runc`). Khi làm lại sau này, xem phiên bản mới ở trang releases của từng dự án và đổi biến ở đầu mỗi khối lệnh.

### 7.1 Chuẩn bị cả 3 node

Chạy từ Mac. Script cài và cấu hình mọi thứ một node cần trước `kubeadm`: module kernel, sysctl, containerd, cấu hình registry nội bộ, `kubelet`/`kubeadm`/`kubectl`.

```bash
cat > /tmp/node-prep.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
K8S_MINOR=v1.37
REGISTRY=10.20.0.5:5000

# 1. Kernel module và sysctl. Tài liệu Kubernetes hiện chỉ bắt buộc ip_forward;
#    overlay/br_netfilter và bridge-nf-call-* thêm vào cho chắc (containerd và nhiều CNI dùng tới)
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<S
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
S
sysctl --system >/dev/null

# 2. containerd từ kho apt của Docker
apt-get update
apt-get install -y ca-certificates curl gpg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<D
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
D
apt-get update
apt-get install -y containerd.io

# 3. Cấu hình containerd. File do gói containerd.io cài sẵn tắt plugin CRI, nên
#    sinh lại file mặc định; bật cgroup systemd; trỏ cấu hình registry về /etc/containerd/certs.d
containerd config default > /etc/containerd/config.toml
sed -i -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
       -e "s#^\(\s*config_path = \)''#\1'/etc/containerd/certs.d'#" /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
  || { echo 'LOI: chua bat SystemdCgroup, sua tay /etc/containerd/config.toml'; exit 1; }
grep -q "config_path = '.*/etc/containerd/certs.d" /etc/containerd/config.toml \
  || { echo 'LOI: config_path chua tro ve /etc/containerd/certs.d'; exit 1; }

# Registry nội bộ không có TLS: khai báo http://
mkdir -p "/etc/containerd/certs.d/$REGISTRY"
cat > "/etc/containerd/certs.d/$REGISTRY/hosts.toml" <<H
server = "http://$REGISTRY"

[host."http://$REGISTRY"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
H
systemctl restart containerd

# 4. kubelet, kubeadm, kubectl từ kho chính thức pkgs.k8s.io
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl cri-tools   # cri-tools = crictl; bản kubeadm mới không còn kéo theo gói này
apt-mark hold kubelet kubeadm kubectl      # không cho apt upgrade tự nâng; nâng cụm bằng kubeadm upgrade
systemctl enable kubelet

# Cho crictl biết socket của containerd
printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\n' > /etc/crictl.yaml

echo "XONG: $(hostname) | $(containerd --version) | $(kubeadm version -o short)"
EOF

for h in k8s-cp k8s-w1 k8s-w2; do
  scp /tmp/node-prep.sh "$h:/tmp/" && ssh "$h" 'sudo bash /tmp/node-prep.sh' || break
done
```

Mỗi node phải in dòng `XONG: ...`. Nếu script dừng ở một dòng `LOI`, nghĩa là file cấu hình mặc định của bản containerd hiện tại khác với giả định của lệnh `sed` (chưa xác minh trên mọi bản containerd 2.x). Mở `/etc/containerd/config.toml` và sửa tay:

- Trong khối `[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]` đặt `SystemdCgroup = true`.
- Trong khối `[plugins.'io.containerd.cri.v1.images'.registry]` đặt `config_path = '/etc/containerd/certs.d'`.

Sau đó `sudo systemctl restart containerd` và chạy lại script.

Lúc này `kubelet` khởi động lại liên tục là **bình thường**: nó chờ `kubeadm` tạo cấu hình.

### 7.2 Khởi tạo control plane

```bash
ssh k8s-cp
sudo tee /root/kubeadm-init.yaml >/dev/null <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.20.0.10
nodeRegistration:
  name: k8s-cp
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: homelab
networking:
  podSubnet: 10.244.0.0/16
apiServer:
  certSANs:
    - 10.20.0.10
    - k8s-cp
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
EOF
sudo kubeadm config validate --config /root/kubeadm-init.yaml
sudo kubeadm init --config /root/kubeadm-init.yaml

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes                      # k8s-cp NotReady: đúng, vì chưa có CNI
kubectl get pods -n kube-system        # etcd, apiserver, scheduler, controller-manager chạy; coredns Pending
```

Giải thích cấu hình:

- **`podSubnet: 10.244.0.0/16`**: dải IP cho pod. Không được trùng mạng lab `10.20.0.0/24`, dải service `10.96.0.0/12` hay mạng nhà (`192.168.x.x`). Đó là lý do không dùng dải mặc định `192.168.0.0/16` của Calico.
- **`certSANs`**: thêm IP và tên mà Mac dùng để gọi API server vào certificate. Thiếu thì `kubectl` từ Mac báo lỗi x509.
- **`clusterName: homelab`**: context trong kubeconfig sẽ là `kubernetes-admin@homelab`, không đụng với cụm khác (ví dụ `kind-lab` của senior-lab).
- **`serverTLSBootstrap: true`**: kubelet xin certificate phục vụ HTTPS do CA của cụm ký, thay vì tự ký. Nhờ vậy metrics-server (mục 8.3) xác minh được kubelet mà không phải dùng cờ `--kubelet-insecure-tls`, cờ mà tài liệu metrics-server ghi là chỉ dùng để thử.

**Nên xem để học:** `kubeadm init` đã làm những gì?

- Tạo CA và certificate ở `/etc/kubernetes/pki/`.
- Viết manifest static pod cho 4 thành phần control plane ở `/etc/kubernetes/manifests/`. kubelet đọc thư mục này và tự chạy chúng, không cần API server.
- Tạo các file kubeconfig (`admin.conf`, `kubelet.conf`, ...).
- Cài addon CoreDNS và kube-proxy.

Mở `/etc/kubernetes/manifests/kube-apiserver.yaml` ra đọc: mọi cờ của API server đều nằm ở đó.

### 7.3 Cài Calico (CNI)

Vẫn trên `k8s-cp`:

```bash
CALICO=v3.33.0
# CRD cho Kubernetes 1.36 trở lên (với 1.34/1.35 dùng file v3_projectcalico_org-v1beta1.yaml)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/v3_projectcalico_org.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/tigera-operator.yaml

curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/custom-resources.yaml
sed -i 's#cidr: 192.168.0.0/16#cidr: 10.244.0.0/16#' custom-resources.yaml
grep -n 'cidr\|encapsulation' custom-resources.yaml     # cidr: 10.244.0.0/16, encapsulation: VXLANCrossSubnet

# Bỏ hai document Goldmane và Whisker (lý do ở ghi chú dưới). awk của Debian (mawk) chạy được, không cần cài yq.
awk '
  /^---$/ { if (!skip) printf "%s", buf; buf = ""; skip = 0 }
  /^kind: (Goldmane|Whisker)$/ { skip = 1 }
  { buf = buf $0 "\n" }
  END { if (!skip) printf "%s", buf }
' custom-resources.yaml > cr.yaml && mv cr.yaml custom-resources.yaml
grep '^kind:' custom-resources.yaml     # đúng 2 dòng: Installation, APIServer. Khác thì file thượng nguồn đã đổi, mở ra sửa tay
kubectl create -f custom-resources.yaml

watch kubectl get tigerastatus          # đợi mọi dòng AVAILABLE=True (vài phút), Ctrl+C để thoát
kubectl get nodes                       # k8s-cp Ready
kubectl get pods -n kube-system -l k8s-app=kube-dns    # coredns Running
```

- Calico cài theo kiểu **operator**: `tigera-operator` đọc CR `Installation` trong `custom-resources.yaml` rồi tự dựng và quản lý các thành phần Calico. Đây cũng là cách Strimzi và CloudNativePG hoạt động sau này.
- **`VXLANCrossSubnet`**: gói tin giữa các node cùng subnet (cả 3 node đều ở `10.20.0.0/24`) đi thẳng, không bọc. Chỉ khi khác subnet mới bọc VXLAN.
- Phải sửa `cidr` cho khớp `podSubnet`. Phần hướng dẫn cài bằng operator của Calico không nói nó tự nhận dải của kubeadm.
- **Không cài Goldmane và Whisker.** Từ Calico v3.30, `custom-resources.yaml` mặc định còn tạo CR `Goldmane` (gom flow log từ Felix, mở qua gRPC) và `Whisker` (UI xem flow log). Lab bỏ cả hai vì ngân sách RAM ([ADR-0004](../../docs/adr/0004-single-instance-by-default-on-homelab.md), ticket kiến trúc 04) đã tính là tắt, quan sát của dự án đi qua stack LGTM, và cả hai còn là technology preview ([Calico – Enable Whisker](https://docs.tigera.io/calico/latest/observability/enable-whisker), tra 2026-11-14). Đo trên cụm: goldmane 30 Mi, whisker 33 Mi.
- **Tắt trên cụm đã cài:** `kubectl delete whisker default` rồi `kubectl delete goldmane default`. Docs Calico chỉ hướng dẫn bật, không ghi cách tắt; hành vi dưới đây là quan sát thực tế ngày 2026-11-14 với v3.33.0. Operator gỡ Deployment, Service của hai thành phần và bỏ biến `FELIX_FLOWLOGSGOLDMANESERVER` khỏi DaemonSet `calico-node`, nên `calico-node` rolling restart (`generation` tăng 1); node vẫn `Ready`. Log operator có thể in vài dòng `Reconciler error ... the object has been modified`: đó là xung đột ghi `Installation` giữa hai controller, tự thử lại, vô hại. Kiểm: `kubectl get tigerastatus` không còn `goldmane`, `whisker` và mọi dòng `AVAILABLE=True`.

### 7.4 Thêm 2 worker

Từ Mac:

```bash
JOIN=$(ssh k8s-cp 'sudo kubeadm token create --print-join-command')
for h in k8s-w1 k8s-w2; do ssh "$h" "sudo $JOIN"; done
ssh k8s-cp kubectl get nodes -o wide      # 3 node Ready sau khoảng 1–2 phút
```

Token mặc định hết hạn sau 24 giờ. Muốn thêm node sau này thì chạy lại lệnh `token create`.

### 7.5 Cho control plane nhận pod, duyệt certificate của kubelet

```bash
ssh k8s-cp
# 1. Gỡ taint để pod thường được chạy trên k8s-cp (chỉ hợp với lab 3 node)
kubectl taint nodes k8s-cp node-role.kubernetes.io/control-plane:NoSchedule-

# 2. Duyệt CSR serving certificate của kubelet (do bật serverTLSBootstrap)
kubectl get csr                                    # 3 CSR kubernetes.io/kubelet-serving đang Pending
kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name \
  | xargs -r kubectl certificate approve
kubectl get csr                                    # Approved,Issued
```

- Kubernetes không tự duyệt loại CSR này. Duyệt hàng loạt như trên chỉ ổn trong lab. Cụm thật phải kiểm tra tên và IP trong từng CSR, hoặc dùng controller duyệt tự động như `kubelet-csr-approver`.
- Certificate này hết hạn sau 1 năm. kubelet tự xin cert mới, khi đó lại có CSR `Pending` cần duyệt. Thêm node mới cũng vậy.

**3. Dàn lại CoreDNS ra các node.** CoreDNS được tạo lúc `kubeadm init`, khi cụm mới có `k8s-cp`, nên cả 2 pod nằm trên node này. Deployment của kubeadm chỉ có anti-affinity `preferred`, không tự dàn lại khi worker join. Mất `k8s-cp` là mất DNS trong cụm (quan sát 2026-11-14, ticket G0-02).

```bash
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide   # 2 pod trên 2 node khác nhau
```

---

## 8. Dùng cụm từ Mac và cài add-on

Mac cần `kubectl` và `helm`: `brew install kubectl helm`.

### 8.1 kubeconfig

```bash
mkdir -p ~/.kube
ssh k8s-cp 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/homelab.yaml
chmod 600 ~/.kube/homelab.yaml

export KUBECONFIG=~/.kube/config:~/.kube/homelab.yaml   # thêm dòng này vào ~/.zshrc
kubectl config rename-context kubernetes-admin@homelab homelab
kubectl config use-context homelab
kubectl get nodes -o wide
```

`admin.conf` đã trỏ tới `https://10.20.0.10:6443`, Mac gọi tới được qua Tailscale. Certificate trong file này hết hạn sau 1 năm. Sau khi gia hạn (`kubeadm certs renew`, mục 10.6) thì copy lại file. Luôn kiểm tra `kubectl config current-context` trước khi chạy lệnh thay đổi.

### 8.2 Storage: local-path-provisioner

kubeadm không có StorageClass nào. Không có nó, PVC của Kafka hay Postgres sẽ kẹt `Pending`.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get storageclass          # local-path (default)
```

- Dữ liệu nằm ở `/opt/local-path-provisioner/` trên **ổ của node mà pod được xếp vào**. Pod gắn chặt với node đó (`volumeBindingMode: WaitForFirstConsumer`). Node chết thì volume tạm mất, nên hệ thống dữ liệu phải tự nhân bản (Kafka RF=3, Postgres có replica).
- `reclaimPolicy: Delete`: xóa PVC là xóa luôn dữ liệu.

### 8.3 metrics-server (`kubectl top`)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top nodes
```

metrics-server 0.9.x hỗ trợ Kubernetes 1.34 trở lên. Nếu log báo lỗi x509 khi gọi kubelet, nghĩa là CSR ở mục 7.5 chưa được duyệt.

### 8.4 MetalLB: IP cho Service kiểu LoadBalancer

```bash
helm repo add metallb https://metallb.github.io/metallb && helm repo update
helm install metallb metallb/metallb -n metallb-system --create-namespace --version 0.16.2 \
  --set speaker.frr.enabled=false --set frrk8s.enabled=false     # chỉ dùng L2, không cần BGP/FRR
kubectl -n metallb-system wait --for=condition=Available deploy --all --timeout=180s

kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.20.0.200-10.20.0.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
EOF
```

- kube-proxy của kubeadm mặc định chạy chế độ **iptables**, nên không cần bật `strictARP`. Tài liệu MetalLB chỉ yêu cầu `strictARP` khi kube-proxy chạy chế độ IPVS.
- Ở chế độ L2, MetalLB trả lời ARP cho IP ảo bằng MAC của chính node, nên thường **không cần** bật MAC spoofing trên Hyper-V. Nếu không truy cập được IP ảo, xem mục 11.

### 8.5 Kiểm tra end-to-end

```bash
# Mạng + LoadBalancer
kubectl create deployment hello --image=nginx:alpine
kubectl expose deployment hello --type=LoadBalancer --port=80
kubectl get svc hello -w            # đợi EXTERNAL-IP trong dải 10.20.0.200–250
curl http://<EXTERNAL-IP>           # trang chào của nginx, gọi thẳng từ Mac
kubectl delete svc,deploy hello

# Storage
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pvc
spec:
  containers:
    - name: c
      image: busybox:stable
      command: ["sh", "-c", "echo ok > /data/f && sleep 3600"]
      volumeMounts:
        - { name: d, mountPath: /data }
  volumes:
    - name: d
      persistentVolumeClaim:
        claimName: test-pvc
EOF
kubectl get pvc test-pvc -w         # Bound
kubectl delete pod/test-pvc pvc/test-pvc
```

Cả hai đều chạy được nghĩa là cả chuỗi đã thông: Mac → Tailscale → gw → mạng lab → MetalLB → pod, và pod có ổ lưu dữ liệu.

### 8.6 Cửa vào cụm: Gateway API với Envoy Gateway (bắt buộc)

Mọi traffic từ trình duyệt vào cụm đi qua **Gateway API** (CRD standard channel **v1.6.1**) hiện thực bằng **Envoy Gateway v1.10.0**, qua một Gateway dùng chung tên **`edge`** (namespace `edge`, listener HTTPS wildcard `*.lab.internal`, HTTP chuyển sang HTTPS). Không dùng Ingress hay `ingress-nginx`: Ingress API đã đóng băng, còn `ingress-nginx` ngừng phát triển và được lưu trữ (archive) từ 24/03/2026. Quyết định ở [ADR-0013](../../docs/adr/0013-gateway-api-envoy-gateway-shared-edge.md), checklist và nguồn ở [cluster-entry.md](../../docs/standards/cluster-entry.md).

- **Cài bằng GitOps, không `helm install` tay.** CRD Gateway API, Envoy Gateway (chart `oci://docker.io/envoyproxy/gateway-helm`, ghim `v1.10.0`, không cài CRD từ chart), `GatewayClass envoy`, `EnvoyProxy` và Gateway `edge` thuộc app `platform` của repo `gitops`. Thứ tự sync wave: CRD Gateway API → cert-manager → trust-manager và Envoy Gateway → Gateway `edge`, `ClusterIssuer lab-ca` → app ([gitops-argocd.md](../../docs/standards/gitops-argocd.md)). Vì vậy mục này cần Argo CD đã bootstrap và CA của mục 8.8.
- **Tương thích:** Envoy Gateway v1.10 hỗ trợ Kubernetes v1.34–v1.37 và hết hỗ trợ ngày 05/05/2027. Mỗi lần nâng cụm phải xem lại bảng matrix (mục 10.6).
- **Tài nguyên ở lab:** Envoy 1 replica, limit đặt tay: controller 256 Mi, Envoy 128 Mi, shutdown-manager 32 Mi (đã tính trong bảng RAM ở mục 0).
- **IP cố định:** Service của Envoy nhận `10.20.0.200` từ MetalLB qua annotation `metallb.io/loadBalancerIPs` (đặt trong `EnvoyProxy`), giữ `externalTrafficPolicy: Local`. Trước khi sync, kiểm không Service LoadBalancer nào khác đang giữ IP này (`kubectl get svc -A | grep 10.20.0.200`), vì IP này nằm trong dải tự cấp `lab-pool` của mục 8.4.

Kiểm tra sau khi sync (bảng đầy đủ ở mục "Bằng chứng cần có" của [cluster-entry.md](../../docs/standards/cluster-entry.md#bằng-chứng-cần-có)):

```bash
kubectl -n edge get gateway edge                                           # PROGRAMMED True
kubectl -n envoy-gateway-system get svc -l app.kubernetes.io/name=envoy    # EXTERNAL-IP 10.20.0.200
curl -sI http://app.lab.internal | head -n 3                               # sau mục 8.7: 301, Location https://...
```

### 8.7 DNS `lab.internal`

Domain của lab là **`lab.internal`** ([ADR-0014](../../docs/adr/0014-lab-pki-and-dns.md)); ICANN giữ `.INTERNAL` cho dùng riêng. Một nguồn sự thật duy nhất: **dnsmasq trên `gw`** trả mọi `*.lab.internal` về `10.20.0.200` (Gateway `edge`). Mac hỏi qua split DNS của Tailscale, pod hỏi qua CoreDNS. Thêm hostname mới không phải sửa DNS.

**1. dnsmasq trên `gw`.** Viết file cấu hình **trước**, rồi mới cài gói `dnsmasq` của Debian: gói tự khởi động dịch vụ ngay khi cài, và nếu chưa có file này thì dnsmasq chạy cấu hình mặc định (nghe mọi interface, forward ra `1.1.1.1`, tức là resolver mở) cho tới lần restart. Năm dòng cấu hình theo checklist "DNS của lab" của [cluster-entry.md](../../docs/standards/cluster-entry.md#dns-của-lab):

```bash
ssh gw
sudo install -d -m 0755 /etc/dnsmasq.d
sudo tee /etc/dnsmasq.d/lab-internal.conf >/dev/null <<'EOF'
# DNS của lab: chỉ trả lời *.lab.internal, không làm resolver mở (ADR-0014, cluster-entry.md).
no-resolv
bind-interfaces
listen-address=10.20.0.5
address=/lab.internal/10.20.0.200
# AAAA, MX... của tên trong lab.internal ra NOERROR rỗng (NODATA) thay vì REFUSED.
local=/lab.internal/
EOF
sudo apt install -y dnsmasq
sudo dnsmasq --test                       # dnsmasq: syntax check OK.
sudo systemctl enable dnsmasq && sudo systemctl restart dnsmasq   # gói đã tự chạy lúc cài; restart để chắc đã nạp file cấu hình
sudo ss -lunpt 'sport = :53'              # chỉ 10.20.0.5:53 (udp và tcp), không có 0.0.0.0:53
cat /etc/resolv.conf                      # vẫn 1.1.1.1 / 8.8.8.8
```

- **`local=/lab.internal/`** là dòng thứ năm, thêm sau khi kiểm thật ngày 2026-11-14 (dnsmasq 2.90-4~deb12u2). Thiếu nó, truy vấn AAAA cho `x.lab.internal` trả `REFUSED`, vì `address=` chỉ có IPv4 nên dnsmasq định forward AAAA mà `no-resolv` không có upstream. macOS hỏi A và AAAA song song, nên `REFUSED` dễ bị coi là lỗi server. Có dòng này, AAAA ra `NOERROR` không có answer, đúng ngữ nghĩa "tên có, không có bản ghi IPv6".
- **Hook `resolvconf`:** đã kiểm ngày 2026-11-14, `gw` không cài `resolvconf` hay `systemd-resolved`, và `/etc/resolv.conf` không đổi sau khi cài dnsmasq.
- Gói Debian chạy dnsmasq với `--local-service`. Cờ này chỉ nhận truy vấn từ subnet nối trực tiếp, nên sẽ chặn Mac (IP tailnet `100.x`). Nó **không có tác dụng** khi có `listen-address` (theo `man dnsmasq`), nên Mac vẫn hỏi được.
- RAM đo được: `MemoryCurrent` khoảng 0,7 MiB.

Kiểm từ Mac:

```bash
dig @10.20.0.5 app.lab.internal +short                      # 10.20.0.200
dig @10.20.0.5 a.b.lab.internal +short                      # 10.20.0.200 (address= phủ mọi mức subdomain)
dig @10.20.0.5 app.lab.internal AAAA | grep status          # NOERROR (ANSWER: 0)
dig @10.20.0.5 app.lab.internal +tcp +short                 # 10.20.0.200 (DNS qua TCP cũng phải chạy)
dig @10.20.0.5 example.com | grep status                    # REFUSED: không phải resolver mở
```

**2. Split DNS của Tailscale.** login.tailscale.com → **DNS** → **Add nameserver** → **Custom**: `10.20.0.5`, bật **Restrict to domain** với `lab.internal`. IP này tới được qua subnet route `10.20.0.0/24` (grant ở Phụ lục A3 đã cho phép). Trên Mac, Tailscale phải bật dùng DNS của Tailscale. Kiểm bằng `dscacheutil` (không dùng `nslookup`, vì nó có thể không đi qua cấu hình DNS của macOS):

```bash
# Bản app trên macOS: CLI nằm trong bundle, có thể chưa có trong PATH
/Applications/Tailscale.app/Contents/MacOS/Tailscale dns status | sed -n '/Split DNS Routes/,/Search Domains/p'   # có dòng lab.internal -> 10.20.0.5
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder            # bắt buộc nếu đã từng hỏi tên này trước khi cấu hình
dscacheutil -q host -a name app.lab.internal    # ip_address: 10.20.0.200
dscacheutil -q host -a name github.com          # vẫn ra IP công khai: split DNS không chiếm domain khác
```

Quan sát ngày 2026-11-14 (Tailscale 1.104.5, macOS 27.2):

- **Không có resolver `domain : lab.internal` trong `scutil --dns`, và đó là bình thường.** App Tailscale trên macOS đăng ký `100.100.100.100` làm resolver bổ sung (`Supplemental`) không gắn domain, xếp trước DNS của máy. Mọi truy vấn đi vào quad-100 trước, và quad-100 tự chia: `lab.internal` gửi tới `10.20.0.5`, tên khác gửi tới DNS của máy. Vì vậy kiểm việc chia bằng `tailscale dns status`, không bằng `scutil`.
- **Kết quả âm bị cache rất lâu.** Nếu đã hỏi `x.lab.internal` trước khi thêm nameserver, `mDNSResponder` cache câu trả lời "không tồn tại" (đo bằng `dns-sd -G v4 x.lab.internal`: `No Such Record`, TTL 108002 giây). Phải xóa cache bằng lệnh `flushcache` ở trên thì mới thấy kết quả mới.

`gw` vẫn giữ `--accept-dns=false` (mục 5); bản thân `gw` không cần phân giải `lab.internal`.

**3. CoreDNS trong cụm.** Pod cũng cần tên này (`seller-web` gọi `https://auth.lab.internal`, `channel-connector` gọi `https://shopee-sim.lab.internal`). Thêm server block vào ConfigMap `kube-system/coredns` (`kubectl -n kube-system edit configmap coredns`), đặt sau block `.:53`:

```
lab.internal:53 {
    errors
    cache 30
    forward . 10.20.0.5
}
```

Nameserver phải là IP. CoreDNS chọn server block có zone cụ thể nhất, nên chỉ tên thuộc `lab.internal` đi block này; mọi tên khác vẫn qua block `.:53`. `kubeadm upgrade` có thể ghi đè Corefile, nên lưu Corefile ra file trước khi sửa, và sau mỗi lần nâng cụm diff lại ConfigMap này (mục 10.6).

Cách sửa không tương tác (thay cho `kubectl edit`, tránh lỗi thụt lề của block scalar `Corefile: |`):

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > coredns-before.Corefile
if grep -q '^lab.internal:53' coredns-before.Corefile; then
  echo "Đã có block lab.internal:53, không thêm nữa"   # chạy lại (ví dụ sau kubeadm upgrade) an toàn
else
  { cat coredns-before.Corefile
    [ -n "$(tail -c1 coredns-before.Corefile)" ] && echo   # bảo đảm block mới bắt đầu ở dòng mới
    cat <<'EOF'
lab.internal:53 {
    errors
    cache 30
    forward . 10.20.0.5
}
EOF
  } > coredns-after.Corefile
  diff coredns-before.Corefile coredns-after.Corefile    # chỉ thêm đúng 5 dòng
  kubectl -n kube-system patch configmap coredns --type merge \
    -p "$(jq -n --rawfile c coredns-after.Corefile '{data:{Corefile:$c}}')"
fi
kubectl -n kube-system logs -l k8s-app=kube-dns -f --prefix | grep -i reload   # đợi cả 2 pod "Reloading complete"
```

Đo ngày 2026-11-14 (CoreDNS v1.14.6): từ lúc patch tới khi cả hai pod in `Reloading complete` mất khoảng 78 giây (kubelet đồng bộ ConfigMap vào pod rồi plugin `reload` mới thấy). Kiểm:

```bash
kubectl run -it --rm dns --image=busybox:stable --restart=Never -- sh -c '
  nslookup auth.lab.internal                        # 10.20.0.200
  nslookup kubernetes.default.svc.cluster.local     # 10.96.0.1: tên trong cụm vẫn chạy
  nslookup github.com                               # IP công khai: tên ngoài vẫn qua block .:53
  nslookup -type=AAAA auth.lab.internal             # không lỗi, không có địa chỉ (NODATA từ dnsmasq)'
```

### 8.8 CA của lab: root offline, tin root trên Mac

Lab dùng CA nội bộ, không dùng chứng chỉ công khai ([ADR-0014](../../docs/adr/0014-lab-pki-and-dns.md)). Thông số và nguồn ở mục "PKI và cert-manager" của [cluster-entry.md](../../docs/standards/cluster-entry.md#pki-và-cert-manager).

1. **Tạo root CA một lần, offline trên Mac**, bằng script `scripts/lab-ca/make-root.sh` của repo `platform` (script không chứa khóa): khóa EC P-384 mã hóa bằng passphrase, hạn 10 năm, `CA:TRUE`, `keyCertSign, cRLSign`, **name constraints critical** chỉ cho DNS `lab.internal`, `svc`, `svc.cluster.local` và **cấm mọi IP SAN** (IPv4, IPv6). Khóa root **không vào Git và không vào cụm**; cất ngoài máy (ổ mã hóa hoặc password manager, như bản backup khóa Sealed Secrets). Phần công khai `pki/lab-root-ca.crt` được commit vào repo `platform`. Mất khóa root thì phải tạo root mới và tin lại ở mọi nơi.

   ```bash
   cd platform
   scripts/lab-ca/test-constraints.sh     # 18 PASS: hành vi script (chạy lại, ký lỗi, khóa trong repo) và root tạm → intermediate → leaf
   scripts/lab-ca/make-root.sh            # hỏi passphrase; khóa ở ~/lab-ca/, chứng chỉ ở pki/lab-root-ca.crt
   openssl x509 -in pki/lab-root-ca.crt -noout -ext nameConstraints   # Permitted 3 DNS, Excluded 2 IP
   ```

   - Script tự tìm OpenSSL 3/4 (Homebrew) và bỏ qua `/usr/bin/openssl`, vì đó là LibreSSL; từ chối chạy khi đã có khóa hoặc chứng chỉ, vì chạy lại là đổi root.
   - **Vì sao cấm IP:** name constraints chỉ ràng buộc loại tên được liệt kê (RFC 5280 §4.2.1.10). Chỉ ghi DNS thì chứng chỉ mang IP SAN không bị ràng buộc gì, và ai lấy được khóa intermediate trong cụm vẫn ký được chứng chỉ cho một IP bất kỳ mà Mac tin. Lab truy cập HTTPS bằng tên, không cần IP SAN.
   - `test-constraints.sh` dựng intermediate **không** có ràng buộc riêng (tình huống lộ khóa intermediate) và kiểm OpenSSL từ chối `evil.example.com`, `lab.internal.evil.com`, `evillab.internal`, leaf có thêm một tên ngoài, leaf có IP SAN. Đây mới là bằng chứng của OpenSSL; Chrome, Safari, `curl` kiểm ở ticket G0-06, JVM và Node ở G0-07.
2. **Tạo intermediate CA** (hạn 2 năm, cũng có name constraints) ký bằng root, rồi seal thành Sealed Secret `lab-intermediate-ca` ở namespace `cert-manager` (`tls.crt` chứa intermediate rồi root, kèm `tls.key`) và commit vào `gitops`. App `platform` tạo `ClusterIssuer lab-ca` từ Secret này, cert-manager cấp chứng chỉ wildcard `*.lab.internal` cho Gateway `edge`. Dựng lại cụm không phải tạo lại root hay tin lại. Đặt lịch nhắc xoay intermediate trước khi hết hạn 60 ngày.
3. **Tin root trên Mac** (Keychain hệ thống):

   ```bash
   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain lab-root-ca.crt
   ```

   Safari và Chrome đọc Keychain; Firefox có đọc không là **chưa xác minh** (nếu không thì import tay). Kiểm: mở `https://argocd.lab.internal` bằng Safari và Chrome không có cảnh báo; `curl --cacert lab-root-ca.crt -v https://app.lab.internal` thấy chuỗi wildcard ← intermediate ← root.
4. Mọi client mới gọi vào lab (máy khác, runner CI, k6) đều phải tin root này trước. Trong cụm, pod tin root qua trust bundle do trust-manager sinh, chart `app` tự mount ([helm-chart.md](../../docs/standards/helm-chart.md)).

Safari, JDK và Node có thực thi name constraints trên root do người dùng thêm vào hay không: **chưa xác minh**, kiểm theo bảng bằng chứng của cluster-entry.md khi dựng G0.

### 8.9 Mailpit trên `gw`

Keycloak gửi email xác minh và quên mật khẩu tới **Mailpit v1.33.1** chạy trên `gw`, không chạy trong cụm (không tốn RAM của cụm). Cài binary vào `/usr/local/bin` và chạy bằng systemd với user riêng, `MemoryMax=128M`; `gw` không cài Docker (lý do ở mục 6). Tham số: SMTP `10.20.0.5:1025`, UI và API `10.20.0.5:8025`, `--compression 0`, `--max 500`, `--max-message-size` nhỏ. Thông số và nguồn theo checklist "Mailpit trên `gw`" của [cluster-entry.md](../../docs/standards/cluster-entry.md#mailpit-trên-gw).

- Realm của Keycloak (trong `gitops`) đặt SMTP `10.20.0.5:1025`. Mac và runner CI đọc thư ở `http://10.20.0.5:8025`, không qua Gateway.
- SMTP không TLS, UI không xác thực: chấp nhận vì chỉ tới được trong lab và tailnet.
- `gw` chỉ có 2 GB mà đang chạy Tailscale, registry, dnsmasq, Mailpit (và RustFS từ mục 12.1): đo RAM thật ở G0.

```bash
systemctl show mailpit -p MemoryCurrent                 # trên gw: < 128 MiB
curl -s http://10.20.0.5:8025/api/v1/messages | head    # từ Mac
```

---

## 9. Build image trên Mac và chạy trên cụm

**1. Cho Docker Desktop trên Mac đẩy image lên registry không TLS.** Vào Settings → Docker Engine, thêm vào JSON rồi Apply & Restart:

```json
"insecure-registries": ["10.20.0.5:5000"]
```

**2. Build cho amd64.** Thiếu bước này thì pod báo `exec format error`.

```bash
# Dockerfile thường
docker buildx build --platform linux/amd64 -t 10.20.0.5:5000/hello-app:0.1 --push .
curl -s http://10.20.0.5:5000/v2/_catalog       # {"repositories":["hello-app"]}
```

Với Spring Boot `bootBuildImage` (Gradle), đặt platform và registry trong `build.gradle`:

```groovy
tasks.named('bootBuildImage') {
    imagePlatform = 'linux/amd64'
    imageName = "10.20.0.5:5000/${project.name}:${version}"
    publish = true
}
```

Trên Apple Silicon, build image amd64 chạy qua giả lập nên chậm hơn. Khi dự án lớn dần, có thể chạy runner CI ngay trong cụm (amd64 sẵn) để build.

**3. Kiểm tra trên cụm:**

```bash
kubectl run test --image=10.20.0.5:5000/hello-app:0.1 --restart=Never
kubectl get pod test; kubectl delete pod test
```

Pod kéo được image là nhờ file `/etc/containerd/certs.d/10.20.0.5:5000/hosts.toml` trên mỗi node (mục 7.1).

---

## 10. Vận hành hằng ngày

### 10.1 Theo dõi tài nguyên

- Windows: Task Manager → Performance; Hyper-V Manager cho biết RAM và CPU của từng VM.
- **Dung lượng SSD:** `Get-PSDrive D` và `Get-ChildItem D:\Study\lab\HyperV -Recurse -Filter *.vhdx | Measure-Object Length -Sum`. Còn dưới 50 GB trống thì dọn image cũ (`sudo crictl rmi --prune` trên từng node, xóa image cũ trên registry ở `gw`) hoặc thêm SSD.
- Trong cụm: `kubectl top nodes`, `kubectl top pods -A` (nhờ metrics-server ở mục 8.3), `k9s --context homelab`.

### 10.2 Cập nhật Windows hằng tháng (chủ động)

1. Chọn lúc không chạy thí nghiệm. Settings → Windows Update → Install → Restart.
2. Khi Windows tắt, các VM tự shutdown; khi Windows lên, VM tự bật theo thứ tự đã đặt ở mục 4.
3. Sau khoảng 3 phút: `kubectl get nodes` đủ 3 node Ready, `kubectl get csr` không có CSR `Pending`, `kubectl get pods -A` không có pod lỗi.

### 10.3 Cập nhật Debian trong VM

```bash
for h in gw k8s-cp k8s-w1 k8s-w2; do ssh $h 'sudo apt update && sudo apt upgrade -y'; done
```

Debian không tự tạo file `/var/run/reboot-required`. Node nào cần khởi động lại (thường là khi output của `apt` có nâng gói `linux-image-*`; kiểm tra bằng cách so `uname -r` với bản mới nhất trong `ls /boot/vmlinuz-*`) thì làm lần lượt từng node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` → reboot → `kubectl uncordon <node>`. Bản thân việc này đã là bài tập vận hành K8s tốt. Khi đã có Kafka và Postgres trong cụm, drain chỉ chạy qua được nếu PodDisruptionBudget cho phép; làm **từng node một** và chờ dữ liệu đồng bộ lại (Kafka hết under-replicated partition, Postgres replica bắt kịp) rồi mới sang node tiếp theo.

`kubelet`, `kubeadm`, `kubectl` đã bị `apt-mark hold` nên `apt upgrade` không đụng tới. Nâng Kubernetes theo mục 10.6.

### 10.4 Checkpoint và sao lưu

```powershell
# Trước khi làm thay đổi lớn (nâng cấp Kubernetes, thử nghiệm nguy hiểm)
Get-VM gw,k8s-* | Checkpoint-VM -SnapshotName "truoc-thay-doi-$(Get-Date -f yyyyMMdd)"

# Quay lại (khôi phục CẢ 3 node về cùng một checkpoint, nếu không etcd và dữ liệu sẽ lệch nhau)
Get-VMSnapshot -VMName k8s-cp
Get-VM k8s-* | ForEach-Object { Restore-VMSnapshot -VMName $_.Name -Name "<tên checkpoint>" -Confirm:$false }

# Xóa checkpoint khi xong (checkpoint để lâu làm chậm ổ và tốn chỗ)
Get-VM | Get-VMSnapshot | Remove-VMSnapshot
```

Khôi phục node K8s về checkpoint cũ là cách "quay lui" thô. Cách đúng cho từng tầng:

- **etcd** (trạng thái cụm): `etcdctl snapshot save`, chạy trong pod `etcd-k8s-cp` hoặc cài `etcdctl` trên node; certificate ở `/etc/kubernetes/pki/etcd/`. Đây là câu hỏi phỏng vấn kinh điển, nên tự làm một lần cả backup lẫn restore.
- **PostgreSQL**: plugin Barman Cloud của CloudNativePG (WAL archive + base backup) lên object store RustFS trên `gw`; khôi phục luôn dựng cluster mới. `pg_dump` không đủ cho khôi phục theo thời điểm. Xem [tra cứu PostgreSQL trên cụm](../../docs/research/2026-11-postgres-on-cluster.md) và [ADR-0003](../../docs/adr/0003-shared-postgres-cluster.md).
- **Kafka**: dữ liệu đã nhân bản 3 node; với lab chấp nhận dựng lại topic.

Đó cũng là một phần của yêu cầu N10 (RPO/RTO) trong tài liệu yêu cầu.

### 10.5 Tắt và bật lab thủ công

```powershell
Stop-VM k8s-w2,k8s-w1,k8s-cp,gw     # tắt theo thứ tự ngược
Start-VM gw,k8s-cp,k8s-w1,k8s-w2
```

Tắt hẳn một worker (`Stop-VM k8s-w2 -TurnOff`) chính là cách giả lập **node chết** cho thí nghiệm chaos: xem Kafka chọn leader mới, Postgres failover, pod bị đánh dấu và xếp lại sau khoảng 5 phút.

### 10.6 Nâng cấp Kubernetes và certificate

- **Certificate** do kubeadm tạo hết hạn sau **1 năm** (CA: 10 năm). Kiểm tra: `sudo kubeadm certs check-expiration` trên `k8s-cp`. `kubeadm upgrade` tự gia hạn toàn bộ certificate, nên nâng cụm ít nhất mỗi năm một lần là đủ. Gia hạn tay: `sudo kubeadm certs renew all`, rồi khởi động lại các static pod control plane, rồi copy lại `admin.conf` về Mac (mục 8.1).
- **Nâng phiên bản**, mỗi lần chỉ lên **một minor** (ví dụ 1.37 → 1.38). Checkpoint (10.4) và backup etcd trước.
  1. Trên mọi node: đổi `v1.37` thành `v1.38` trong `/etc/apt/sources.list.d/kubernetes.list`, rồi `apt-get update`.
  2. `k8s-cp`: `apt-mark unhold kubeadm`, cài bản kubeadm mới, `apt-mark hold kubeadm`; `sudo kubeadm upgrade plan`; `sudo kubeadm upgrade apply v1.38.x`; drain, nâng `kubelet` và `kubectl` theo cách tương tự, `systemctl restart kubelet`, uncordon.
  3. Từng worker: nâng kubeadm, `sudo kubeadm upgrade node`, drain (chạy từ Mac), nâng kubelet và kubectl, restart kubelet, uncordon.
  4. Xem tài liệu "Upgrading kubeadm clusters" của đúng phiên bản đích trước khi làm, vì mỗi bản có thể có lưu ý riêng. Đọc thêm bảng tương thích của Envoy Gateway và cert-manager với bản Kubernetes đích ([ADR-0013](../../docs/adr/0013-gateway-api-envoy-gateway-shared-edge.md)).
  5. Sau khi nâng: diff ConfigMap `kube-system/coredns` với bản trước khi nâng, đưa lại server block `lab.internal` nếu mất, rồi test phân giải `auth.lab.internal` từ pod (mục 8.7). Docs Kubernetes không nhất quán về việc `kubeadm upgrade` có giữ Corefile hay không ([ADR-0014](../../docs/adr/0014-lab-pki-and-dns.md)).

---

## 11. Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| VM báo "Secure Boot violation" hoặc không tìm thấy hệ điều hành | Sai template Secure Boot | `Set-VMFirmware <vm> -SecureBootTemplate MicrosoftUEFICertificateAuthority`, hoặc `-EnableSecureBoot Off` |
| VM không ra internet | Thiếu NAT hoặc sai gateway/DNS | `Get-NetNat` trên Windows; trong VM: `ip r` (phải có `default via 10.20.0.1`), `cat /etc/resolv.conf` (phải có `nameserver`), sửa IP/gateway trong `/etc/network/interfaces` rồi `sudo systemctl restart networking` |
| `sudo: command not found` hoặc `lab is not in the sudoers file` | Lúc cài Debian đã đặt mật khẩu root, nên bộ cài không cài `sudo` | `su -` (nhập mật khẩu root), `apt install -y sudo && usermod -aG sudo lab`, đăng xuất rồi vào lại |
| Swap vẫn bật sau khi khởi động lại (`swapon --show` có dòng) | Còn phân vùng swap trên ổ | `sudo swapoff -a`, xóa dòng swap trong `/etc/fstab`; vẫn còn thì `systemctl --type swap` để xem tên unit rồi `sudo systemctl mask <unit>` |
| `New-NetNat` báo lỗi | Đã có một NAT khác (WinNAT chỉ cho một) | `Get-NetNat`; chỉ xóa (`Remove-NetNat`) khi chắc chắn không phần mềm nào khác đang dùng |
| Mac không ping được 10.20.0.x | Route chưa được duyệt, hoặc `gw` tắt | Trang quản trị Tailscale: route đã approve chưa; trên gw: `tailscale status`, `sysctl net.ipv4.ip_forward` |
| SSH báo "REMOTE HOST IDENTIFICATION HAS CHANGED" | Máy vừa nhân bản hoặc tạo lại | `ssh-keygen -R <ip>` |
| `kubeadm init` dừng ở preflight | Còn swap, thiếu `ip_forward`, hoặc containerd chưa chạy | Đọc dòng `[ERROR ...]`; `swapon --show`, `sysctl net.ipv4.ip_forward`, `systemctl status containerd` |
| `kubeadm init` treo ở "waiting for the kubelet" | containerd chưa bật CRI hoặc lệch cgroup driver | `journalctl -u kubelet -n 50`; `grep -n 'SystemdCgroup\|disabled_plugins' /etc/containerd/config.toml`; sửa xong `sudo kubeadm reset -f` rồi init lại |
| Node `NotReady`, CoreDNS `Pending` | Chưa cài CNI, hoặc Calico chưa lên | `kubectl get tigerastatus`, `kubectl get pods -n calico-system`; kiểm tra `cidr` trong `custom-resources.yaml` khớp `podSubnet` |
| kubectl từ Mac báo lỗi x509 | IP hoặc tên không có trong `certSANs` | Trên `k8s-cp`: thêm vào `certSANs` của `/root/kubeadm-init.yaml`, chuyển `apiserver.crt` và `apiserver.key` trong `/etc/kubernetes/pki/` ra chỗ khác, chạy `sudo kubeadm init phase certs apiserver --config /root/kubeadm-init.yaml`, rồi khởi động lại pod kube-apiserver (chưa xác minh từng bước; xem tài liệu kubeadm-certs) |
| `kubectl top` hoặc `kubectl logs` báo lỗi x509/tls với kubelet | CSR serving của kubelet chưa duyệt | `kubectl get csr`, duyệt như mục 7.5 |
| PVC kẹt `Pending` | Không có StorageClass mặc định | `kubectl get sc`; làm lại mục 8.2 |
| Service LoadBalancer kẹt `<pending>` | MetalLB chưa chạy hoặc chưa có IPAddressPool | `kubectl get pods,ipaddresspool,l2advertisement -n metallb-system` |
| Có EXTERNAL-IP nhưng không truy cập được | ARP của MetalLB bị chặn | Thử `Set-VMNetworkAdapter -VMName k8s-w1,k8s-w2,k8s-cp -MacAddressSpoofing On` |
| Mac không phân giải `*.lab.internal` | Chưa có split DNS, Tailscale trên Mac không dùng DNS của Tailscale, hoặc dnsmasq trên `gw` không chạy | `dig @10.20.0.5 app.lab.internal +short`; trên gw: `systemctl status dnsmasq`; làm lại mục 8.7 bước 1–2 |
| Pod không phân giải `*.lab.internal` | Thiếu server block trong CoreDNS, thường sau `kubeadm upgrade` | `kubectl -n kube-system get configmap coredns -o yaml`; làm lại mục 8.7 bước 3 |
| Trình duyệt cảnh báo chứng chỉ ở `*.lab.internal` | Mac chưa tin root, hoặc Gateway `edge` chưa có chứng chỉ | Làm lại mục 8.8 bước 3; `kubectl -n edge get certificate` phải `Ready` |
| Pod `ImagePullBackOff` với image `10.20.0.5:5000/...` | Thiếu `hosts.toml` hoặc `config_path`, hoặc chưa restart containerd | Trên node: `cat /etc/containerd/certs.d/10.20.0.5:5000/hosts.toml`, `grep config_path /etc/containerd/config.toml`, `sudo systemctl restart containerd`; thử `sudo crictl pull 10.20.0.5:5000/<image>` |
| Mac không đẩy được image lên registry | Thiếu `insecure-registries` trong Docker Desktop, hoặc registry trên `gw` không chạy | Mục 9 bước 1; trên gw: `systemctl status docker-registry` |
| Pod chạy lỗi `exec format error` | Image arm64 build trên Mac | Build lại với `--platform linux/amd64` |
| Giờ trong VM lệch | Máy từng ngủ, hoặc chrony chưa dùng PTP | `chronyc sources` phải có dòng `PHC0`; tắt sleep trên Windows |
| Node `NotReady` sau khi Windows khởi động lại | Worker lên trước control plane | Đợi vài phút; kiểm tra `AutomaticStartDelay` |
| Muốn làm lại cụm từ đầu | | Trên mọi node: `sudo kubeadm reset -f`, `sudo rm -rf /etc/cni/net.d /var/lib/etcd`; trên `k8s-cp` thêm `rm -rf ~/.kube`; rồi làm lại từ mục 7.2 |

---

## 12. Bước tiếp theo

### 12.1 Hạ tầng dữ liệu trong cụm

Dựng ở giai đoạn 0 của commerce-hub (xem `requirements-and-techniques.md`, mục C18). Nguyên tắc chung cho cả tầng dữ liệu:

- **Mỗi hệ thống một namespace** (`kafka`, `postgres`, `redis`, `search`). **Đặt `resources.requests` và `limits` cho mọi pod.** Cụm sát RAM, thiếu cái này thì một pod ăn quá tay sẽ làm node bị OOM.
- **Pod anti-affinity** theo `kubernetes.io/hostname` để 3 broker Kafka (và primary/replica Postgres) nằm ở 3 node khác nhau. Operator thường có sẵn tùy chọn này.
- **PodDisruptionBudget** để `kubectl drain` không tắt quá nhiều bản sao cùng lúc. Strimzi và CloudNativePG tự tạo PDB.
- Volume dùng `local-path` (mục 8.2), mỗi node một bản sao dữ liệu.

| Thành phần | Cách cài | Ghi chú |
|---|---|---|
| Kafka | **Strimzi** operator (bản 1.3.x trong quickstart, Kafka 4.3.x). Cài operator: `kubectl create namespace kafka`, `kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka` | Viết CR `Kafka` + `KafkaNodePool` 3 node, KRaft (không ZooKeeper), `default.replication.factor: 3`, `min.insync.replicas: 2`, memory 1 Gi, heap 512m mỗi broker (ticket 04 của docs) |
| PostgreSQL | **CloudNativePG** (v1.30.1). Cài bằng manifest `cnpg-1.30.1.yaml` trong trang releases của dự án; lệnh cài chính xác xem trang Installation của CloudNativePG (chưa xác minh) | CR `Cluster` `pg-main`, mặc định `instances: 1` (ADR-0004 của docs). Khi làm thí nghiệm failover thì tăng lên 2 (primary + replica) rồi tắt node đang chạy primary. Backup cần thêm **cert-manager** và plugin **Barman Cloud** v0.16.0, đích là RustFS trên `gw` (MinIO community đã archived) |
| Redis | Helm chart hoặc manifest StatefulSet tự viết, 1 instance | Lab dùng làm cache, mất cũng không sao |
| OpenSearch | OpenSearch Helm chart hoặc OpenSearch operator, **1 node** | Tốn RAM nhất; heap khoảng 1–1,5 GB, đặt `limits` khoảng 3 GB; chỉ bật khi làm phần tìm kiếm |

### 12.2 Việc khác

1. **Hạ tầng dưới dạng code:** viết Ansible playbook cho các mục 3.3, 5, 6, 7. Sau đó xóa hết VM và dựng lại bằng một lệnh, để chắc chắn lab tái lập được.
2. **Phần còn lại của giai đoạn 0:** Argo CD trong cụm, trỏ vào repo `gitops`; Keycloak và stack Grafana (LGTM) trong cụm.
3. **Bài tập vận hành nên làm sớm** (hay bị hỏi khi phỏng vấn): backup và restore etcd; nâng cụm lên một minor (10.6); giả lập node chết (10.5); viết NetworkPolicy chặn traffic giữa namespace (Calico hỗ trợ).
4. Khi nâng RAM lên 64 GB: thêm worker `k8s-w3` (10.20.0.13), chạy OpenSearch nhiều node và ClickHouse; cân nhắc 3 control plane (HA, etcd 3 thành viên) hoặc chuyển CNI sang Cilium.

---

## Phụ lục A: Ở lại Windows 10

Năm việc, làm theo thứ tự. Việc A3 (Tailscale ACL) quan trọng nhất, vì nó ngăn máy Windows (nếu bị nhiễm mã độc) chủ động kết nối tới MacBook.

### A1. Đảm bảo đang ở Windows 10 22H2

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
  Select-Object ProductName, DisplayVersion, CurrentBuild, UBR
```

- Đúng là **`DisplayVersion = 22H2`** và **`CurrentBuild = 19045`**. `UBR` là số bản vá; số càng lớn càng mới.
- Nếu là 21H2/21H1/20H2 (build 19044, 19043, 19042): vào Settings → Update & Security → Windows Update → Check for updates. Bản 22H2 tới dưới dạng "Feature update to Windows 10, version 22H2", cài rất nhanh vì chỉ là gói kích hoạt.
- Sau đó bấm **Check for updates** nhiều lần cho tới khi không còn gì để cài, rồi khởi động lại.

### A2. Đăng ký ESU (bản vá bảo mật mở rộng tới 12/10/2027)

**Điều kiện** (theo trang ESU cho cá nhân của Microsoft):

- Windows 10 22H2 bản Home, Pro, Pro Education **hoặc Workstations**. Máy này đủ điều kiện.
- Đăng nhập bằng **tài khoản Microsoft có quyền admin** (không phải tài khoản trẻ em).
- Máy **không** join domain, Entra ID hay MDM. Máy cá nhân thường không join.

**Cách đăng ký:**

1. Cài hết bản cập nhật ở A1, trong đó có gói chuẩn bị ESU **KB5126256** (ESU Licensing Preparation Package).
2. **Settings → Update & Security → Windows Update** → bấm **Enroll now** (dòng nói về Extended Security Updates).
3. Nếu máy đang dùng tài khoản local, Windows yêu cầu đăng nhập tài khoản Microsoft.
4. Chọn một trong ba cách:
   - **Miễn phí:** đồng bộ cài đặt máy bằng Windows Backup lên tài khoản Microsoft.
   - **Đổi 1.000 điểm Microsoft Rewards.**
   - **Mua một lần 30 USD.** Một giấy phép dùng được cho tối đa 10 máy.
5. Xác nhận. Trang Windows Update sẽ báo máy đã được đăng ký nhận ESU.

**Nếu không thấy nút Enroll now:**

- Chưa cài đủ bản cập nhật: cài hết, khởi động lại, thử lại sau vài giờ.
- Không có cách đăng ký nào khác ngoài Windows Update.

Lưu ý: một số bài hỏi đáp cũ ghi ESU kết thúc 13/10/2026. Trang chính thức hiện ghi **12/10/2027**.

### A3. Tailscale ACL: chỉ cho Mac kết nối vào, không cho Windows kết nối ra

**Nguyên lý:**

- Tailscale chặn mặc định mọi thứ, chỉ cho phép những gì được ghi trong `grants`. Nhưng policy mặc định của một tailnet mới cho phép mọi thiết bị kết nối tới nhau, nên phải tự sửa.
- Ta **gắn tag** cho Windows (`tag:winhost`) và VM gw (`tag:homelab`). Thiết bị đã gắn tag không còn thuộc về user nên không nằm trong `autogroup:member`.
- Chỉ cấp quyền cho `autogroup:member` (Mac, điện thoại của bạn) đi tới Windows, gw và dải lab. Windows không được cấp gì, nên **không chủ động mở được kết nối nào** trong tailnet.
- Kết nối do Mac mở (Remote Desktop, SSH) vẫn nhận được phản hồi bình thường.

**Bước 1: sửa policy.** login.tailscale.com → **Access controls** → chế độ chỉnh JSON. Thay phần `grants` (hoặc `acls`) và thêm `tagOwners`, `autoApprovers`. Giữ nguyên khối `ssh` nếu có.

```json
{
  "tagOwners": {
    "tag:winhost": ["autogroup:admin"],
    "tag:homelab": ["autogroup:admin"]
  },

  "grants": [
    // Thiết bị cá nhân (Mac, điện thoại) được vào: chính các thiết bị cá nhân khác,
    // máy Windows, VM gw và toàn bộ dải lab qua subnet router.
    {
      "src": ["autogroup:member"],
      "dst": ["autogroup:self", "tag:winhost", "tag:homelab", "10.20.0.0/24"],
      "ip":  ["*"]
    }
    // Không có grant nào có src là tag:winhost hay tag:homelab,
    // nên hai thiết bị này không tự mở kết nối được tới thiết bị nào khác trong tailnet.
  ],

  // Tự duyệt route 10.20.0.0/24 khi nó được quảng bá từ máy có tag:homelab
  "autoApprovers": {
    "routes": { "10.20.0.0/24": ["tag:homelab"] }
  }
}
```

Bấm **Save**. Trang sẽ báo lỗi ngay nếu JSON sai cú pháp.

**Bước 2: gắn tag.** Vào **Machines**:

- Máy Windows → `…` → **Edit ACL tags** → thêm `tag:winhost` → Save.
- Máy `gw` → `…` → **Edit ACL tags** → thêm `tag:homelab` → Save.
- Thiết bị có tag tự tắt hết hạn key, nên không cần "Disable key expiry" nữa.
- Kiểm tra lại máy `gw` vẫn có route `10.20.0.0/24` ở trạng thái đã duyệt. `autoApprovers` sẽ tự duyệt; nếu chưa thì duyệt tay như mục 5.

**Bước 3: kiểm tra cả hai chiều.**

Trên Mac (phải thành công):

```bash
tailscale status                         # ghi lại IP 100.x của Mac và của Windows
nc -vz <IP-100.x-của-Windows> 3389       # cổng Remote Desktop mở
ssh lab@10.20.0.10 hostname              # vẫn vào được lab
```

Trên Windows, trong PowerShell (phải thất bại):

```powershell
Test-NetConnection <IP-100.x-của-Mac> -Port 22   # TcpTestSucceeded : False
ping <IP-100.x-của-Mac>                          # Request timed out
```

Nếu Mac chưa bật Remote Login (SSH) thì cổng 22 luôn đóng, nên kết quả trên chưa chứng minh được gì. Cách kiểm tra chắc chắn: tạm bật **System Settings → General → Sharing → Remote Login** trên Mac, chạy lại lệnh trên Windows (vẫn phải thất bại), rồi tắt Remote Login đi.

### A4. Làm cứng Windows

Mục tiêu: giảm khả năng chính máy Windows bị nhiễm mã độc.

**1. Dùng tài khoản thường (không phải admin) cho việc hằng ngày.**

- Settings → Accounts → Family & other users → **Add someone else to this PC** → tạo tài khoản mới, để loại **Standard user**.
- Dùng tài khoản này để lướt web và làm việc. Chỉ đăng nhập tài khoản admin (tài khoản Microsoft đã đăng ký ESU) khi cần cài phần mềm hoặc quản lý Hyper-V. Phần lớn mã độc cần quyền admin để bám rễ vào máy.
- Các VM vẫn chạy nền bình thường dù đang đăng nhập tài khoản nào, vì chúng do dịch vụ Hyper-V quản lý.

**2. Kiểm tra Microsoft Defender và Firewall đang bật:**

```powershell
Get-MpComputerStatus | Select-Object AMServiceEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated
Get-NetFirewallProfile | Select-Object Name, Enabled          # cả 3 profile phải True
Update-MpSignature                                            # cập nhật nhận diện mã độc ngay
```

Bật thêm **Controlled folder access** để chống ransomware mã hóa thư mục tài liệu: Windows Security → Virus & threat protection → Ransomware protection → On.

**3. Chỉ cho Remote Desktop nhận kết nối từ Tailscale.** Mặc định Remote Desktop mở cho cả mạng LAN; giới hạn lại chỉ dải `100.64.0.0/10` của Tailscale:

```powershell
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Where-Object Enabled -eq 'True' |
  Set-NetFirewallRule -RemoteAddress 100.64.0.0/10
```

Thử Remote Desktop từ Mac qua Tailscale: vẫn vào được.

**4. Tắt SMBv1**, giao thức cũ từng bị WannaCry khai thác:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol | Select-Object State
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart
```

**5. Thói quen sử dụng:**

- Trình duyệt luôn cập nhật bản mới.
- Không cài phần mềm crack hoặc không rõ nguồn gốc.
- Không mở file đính kèm lạ trên máy này.
- Việc "rủi ro" làm trên Mac (vẫn được vá đầy đủ).

**6. (Tùy chọn) Bật BitLocker** cho ổ C: (Control Panel → BitLocker Drive Encryption) để chống lộ dữ liệu khi mất máy. Lưu recovery key vào tài khoản Microsoft hoặc in ra giấy.

### A5. Chuẩn bị để sau này nâng cấp lên Windows 11

Làm vào một cuối tuần, khi lab không chạy thí nghiệm.

1. **Chuẩn bị ổ ngoài** (USB/SSD rời) đủ chỗ cho dữ liệu cá nhân và các VM. Kiểm tra dung lượng thực của VM bằng `Get-ChildItem D:\Study\lab\HyperV -Recurse -Filter *.vhdx | Measure-Object Length -Sum`.
2. **Sao lưu dữ liệu cá nhân** ra ổ ngoài.
3. **Ghi lại BitLocker recovery key** nếu đã bật: `manage-bde -protectors -get C:`.
4. **Tắt và export toàn bộ VM:**

   ```powershell
   Stop-VM k8s-w2,k8s-w1,k8s-cp,gw
   Export-VM -Name gw,k8s-cp,k8s-w1,k8s-w2,debian-golden -Path 'E:\hyperv-export'   # E: là ổ ngoài
   ```

   Bản export gồm cấu hình và ổ ảo, dùng `Import-VM` để khôi phục nếu nâng cấp gặp sự cố.
5. **Ghi lại cấu hình mạng** để dựng lại khi cần: `Get-VMSwitch; Get-NetNat; Get-NetIPAddress -IPAddress 10.20.0.1`.
6. **Nâng cấp** theo mục 1.1 (PC Health Check → Windows Update hoặc Installation Assistant).
7. **Sau khi nâng cấp**, kiểm tra:

   ```powershell
   Get-VM                                    # đủ 5 VM
   Get-VMSwitch; Get-NetNat                  # switch LabNAT và NAT còn nguyên
   ```

   - Nếu mất NAT, chạy lại lệnh ở mục 2.
   - Kiểm tra lại các thiết lập ở 1.4 (chế độ ngủ, Windows Update) vì nâng cấp có thể đặt lại.
   - Bật các VM, rồi chạy `kubectl get nodes` từ Mac.
8. Xong thì xóa thư mục export trên ổ ngoài, hoặc giữ làm bản sao lưu.

---

## Nguồn

- Windows 10 ESU cho cá nhân: [Consumer ESU](https://www.microsoft.com/en-us/windows/extended-security-updates) · [Hỏi đáp về cách đăng ký](https://learn.microsoft.com/en-us/answers/questions/5489827/how-to-enroll-windows-10-in-extended-security-upda)
- Tailscale policy: [Cú pháp policy file](https://tailscale.com/docs/reference/syntax/policy-file) · [Ví dụ grants](https://tailscale.com/docs/reference/examples/grants)

- Windows: [Windows 10 lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/windows-10-home-and-pro) · [Windows 10 end of support và ESU](https://www.microsoft.com/en-us/windows/end-of-support) · [CPU Intel hỗ trợ Windows 11](https://learn.microsoft.com/en-us/windows-hardware/design/minimum/supported/windows-11-supported-intel-processors) · [Yêu cầu hệ thống Windows 11](https://support.microsoft.com/en-us/windows/windows-11-system-requirements-86c11283-ea52-4782-9efd-7674389a7ba3) · [Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information) · [Windows Update: restart](https://learn.microsoft.com/en-us/windows/deployment/update/waas-restart) · [Windows Update settings](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings) · [powercfg](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)
- Hyper-V: [Cài Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v) · [Yêu cầu phần cứng](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements) · [Mạng NAT](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network) · [New-VMSwitch](https://learn.microsoft.com/en-us/powershell/module/hyper-v/new-vmswitch) · [Set-VM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vm) · [Set-VMFirmware](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmfirmware) · [Set-VMNetworkAdapter](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmnetworkadapter) · [Best practices chạy Linux trên Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/best-practices-for-running-linux-on-hyper-v) · [Debian trên Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-debian-virtual-machines-on-hyper-v) · [Đồng bộ giờ cho Linux VM](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/time-sync)
- Debian: [Debian LTS (lịch hỗ trợ bookworm)](https://wiki.debian.org/LTS) · [Hướng dẫn cài Debian 12: mạng, user, root/sudo](https://www.debian.org/releases/bookworm/amd64/ch06s03.en.html) · [chrony.conf mặc định của bookworm (`confdir /etc/chrony/conf.d`)](https://sources.debian.org/src/chrony/bookworm/debian/chrony.conf/) · [Rule udev `ptp_hyperv` trong systemd 252](https://github.com/systemd/systemd/blob/v252/rules.d/50-udev-default.rules.in) · [Gói `docker-registry` (chỉ có ở bookworm-backports; file cấu hình, service)](https://sources.debian.org/src/docker-registry/)
- Tailscale: [Cài trên Linux](https://tailscale.com/kb/1031/install-linux) · [Subnet routers](https://tailscale.com/kb/1019/subnets) · [Kernel và userspace router](https://tailscale.com/docs/reference/kernel-vs-userspace-routers) · [Tối ưu hiệu năng](https://tailscale.com/kb/1320/performance-best-practices) · [Key expiry](https://tailscale.com/kb/1028/key-expiry) · [Tags](https://tailscale.com/kb/1068/tags)
- Kubernetes: [Phiên bản stable](https://dl.k8s.io/release/stable.txt) · [Releases và thời hạn hỗ trợ](https://kubernetes.io/releases/) · [Cài kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) · [Container runtimes (sysctl, cgroup driver)](https://kubernetes.io/docs/setup/production-environment/container-runtimes/) · [Tạo cụm bằng kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/) · [kubeadm config v1beta4](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/) · [kubeadm token](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/) · [Certificate với kubeadm (kubelet serving cert)](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/) · [Cổng mạng](https://kubernetes.io/docs/reference/networking/ports-and-protocols/) · [Đổi StorageClass mặc định](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/) · [Ingress NGINX retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- containerd và Docker: [containerd getting started](https://github.com/containerd/containerd/blob/main/docs/getting-started.md) · [Cấu hình registry (hosts.toml, config_path)](https://github.com/containerd/containerd/blob/main/docs/hosts.md) · [Kho apt của Docker cho Debian](https://docs.docker.com/engine/install/debian/)
- Calico: [Cài trên cụm tự quản lý](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises) · [Yêu cầu hệ thống](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements) · [Releases](https://github.com/projectcalico/calico/releases)
- MetalLB: [Cài đặt (strictARP chỉ cho IPVS, Helm)](https://metallb.io/installation/) · [Cấu hình L2](https://metallb.io/configuration/) · [Releases](https://github.com/metallb/metallb/releases)
- Cửa vào cụm, DNS, CA, Mailpit (tra 13/11/2026; danh sách đầy đủ ở [cluster-entry.md](../../docs/standards/cluster-entry.md#nguồn)): [Kubernetes – Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) · [Gateway API releases](https://github.com/kubernetes-sigs/gateway-api/releases) · [Envoy Gateway – Compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/) · [Envoy Gateway – Install with Argo CD](https://gateway.envoyproxy.io/docs/install/install-argocd/) · [MetalLB – Usage](https://metallb.io/usage/) · [cert-manager – CA](https://cert-manager.io/docs/configuration/ca/) · [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) · [ICANN – `.INTERNAL`](https://www.icann.org/en/board-activities-and-meetings/materials/approved-resolutions-special-meeting-of-the-icann-board-29-07-2024-en) · [dnsmasq man page](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html) · [Tailscale – DNS](https://tailscale.com/kb/1054/dns) · [Customizing DNS Service (CoreDNS)](https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/) · [Reconfiguring a kubeadm cluster](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/) · `man security` (macOS) · [Chrome Root Store FAQ](https://chromium.googlesource.com/chromium/src/+/main/net/data/ssl/chrome_root_store/faq.md) · [Mailpit – Install](https://mailpit.axllent.org/docs/install/) · [Mailpit – Runtime options](https://mailpit.axllent.org/docs/configuration/runtime-options/)
- Add-on khác: [local-path-provisioner](https://github.com/rancher/local-path-provisioner) · [metrics-server](https://github.com/kubernetes-sigs/metrics-server) · [Envoy Gateway quickstart](https://gateway.envoyproxy.io/docs/tasks/quickstart/) · [Strimzi quickstart](https://strimzi.io/quickstarts/) · [CloudNativePG releases](https://github.com/cloudnative-pg/cloudnative-pg/releases)
- Spring Boot 4.1: Gradle plugin, Packaging OCI Images (`bootBuildImage`)
