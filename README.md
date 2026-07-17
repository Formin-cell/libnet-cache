# libnet-cache

`libnet-cache` is a high-performance, lightweight network data stream caching library and tool designed specifically for Linux environments. It bridges the gap between ultra-low-latency cache mechanisms and flexible Shell-driven automation, making it ideal for network proxies, data distribution pipelines, and edge computing nodes.

##  Key Features

*   **Blazing Fast Cache Engine**: Low-latency caching of network packets and data streams using optimized cache eviction algorithms (LRU/LFU).
*   **Automated Network Tuning**: Built-in intelligent Shell scripts that automatically optimize Linux kernel network stacks (`sysctl` TCP/IP tuning).
*   **Zero-Dependency Deployment**: A robust installation script that automatically detects the host environment, installs missing dependencies, and configures permissions.
*   **Daemon & CLI Modes**: Can run seamlessly as a background daemon system service or as a standard pipeline CLI tool.
