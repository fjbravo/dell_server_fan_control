# MQTT Architecture for Dell Server Fan Control

This document provides a visual overview of the MQTT integration architecture for the Dell Server Fan Control system.

## System Architecture

```mermaid
flowchart TD
    subgraph "Dell Server"
        A[Fan Control Script] --> B[Temperature Monitoring]
        B --> C[Fan Speed Control]
        A --> D[MQTT Client]
    end
    
    subgraph "MQTT Broker"
        E[Mosquitto]
    end
    
    subgraph "Monitoring Systems"
        F[Home Assistant]
        G[Grafana]
        H[Custom Dashboards]
        I[Mobile Apps]
    end
    
    D -->|Publish| E
    E -->|Subscribe| F
    E -->|Subscribe| G
    E -->|Subscribe| H
    E -->|Subscribe| I
```

## Message Flow

```mermaid
sequenceDiagram
    participant FC as Fan Control
    participant MQTT as MQTT Client
    participant Broker as MQTT Broker
    participant Monitor as Monitoring System
    
    FC->>FC: Monitor temperatures
    FC->>FC: Calculate fan speeds
    FC->>FC: Control fans
    FC->>MQTT: Send metrics
    
    alt Successful Connection
        MQTT->>Broker: Publish metrics
        Broker->>Monitor: Forward metrics
        Monitor->>Monitor: Update dashboard
    else Connection Failure
        MQTT--xBroker: Connection timeout
        MQTT->>MQTT: Increment failure count
        MQTT->>MQTT: Check if count > threshold
        
        alt Count > Threshold
            MQTT->>MQTT: Open circuit breaker
            MQTT->>FC: Continue fan control without MQTT
        else Count <= Threshold
            MQTT->>FC: Continue with retry on next cycle
        end
    end
```

## Circuit Breaker Pattern

```mermaid
stateDiagram-v2
    [*] --> Closed
    
    state Closed {
        [*] --> Operational
        Operational --> Failed: Connection Failure
        Failed --> Operational: Successful Connection
        Failed --> CircuitOpen: Failure Count > Threshold
    }
    
    state Open {
        [*] --> Disabled
        Disabled --> AttemptReset: Random Interval
        AttemptReset --> Disabled: Connection Failure
        AttemptReset --> HalfOpen: Successful Connection
    }
    
    Closed --> Open: Circuit Opens
    Open --> Closed: Circuit Closes
    
    state HalfOpen {
        [*] --> Testing
        Testing --> Closed: Successful Connection
        Testing --> Open: Connection Failure
    }
```

## Topic Structure

```mermaid
graph TD
    A[servers/] --> B[hostname/]
    B --> C[metrics]
    B --> D[status]
    
    style A fill:#f9f,stroke:#333,stroke-width:2px
    style B fill:#bbf,stroke:#333,stroke-width:2px
    style C fill:#bfb,stroke:#333,stroke-width:2px
    style D fill:#bfb,stroke:#333,stroke-width:2px
```

## Deployment Options

```mermaid
flowchart LR
    subgraph "Option 1: Docker on Same Host"
        A1[Fan Control] -->|localhost| B1[Docker MQTT]
    end
    
    subgraph "Option 2: Remote MQTT Broker"
        A2[Fan Control] -->|network| B2[Remote MQTT]
    end
    
    subgraph "Option 3: Cloud MQTT"
        A3[Fan Control] -->|internet| B3[Cloud MQTT]
    end
    
    subgraph "Clients"
        C[Monitoring Systems]
    end
    
    B1 -->|local network| C
    B2 -->|local network| C
    B3 -->|internet| C
```

## Component Interaction

```mermaid
classDiagram
    class FanControl {
        +monitor_temperatures()
        +calculate_fan_speeds()
        +set_fan_speeds()
        +publish_metrics()
    }
    
    class MQTTClient {
        -broker: string
        -port: int
        -failure_count: int
        -circuit_open: bool
        +mqtt_publish()
        +mqtt_publish_metrics()
        +mqtt_publish_status()
        +mqtt_reset_failures()
    }
    
    class CircuitBreaker {
        -failure_threshold: int
        -timeout: int
        +is_open(): bool
        +record_failure()
        +record_success()
        +attempt_reset()
    }
    
    FanControl --> MQTTClient: uses
    MQTTClient --> CircuitBreaker: implements
```

## Security Model

```mermaid
flowchart TD
    subgraph "Security Levels"
        A[No Security] -->|Upgrade| B[Username/Password]
        B -->|Upgrade| C[TLS Encryption]
        C -->|Upgrade| D[TLS + Client Certificates]
    end
    
    subgraph "Attack Vectors"
        E[Message Interception]
        F[Unauthorized Publishing]
        G[Broker Impersonation]
    end
    
    A -.->|Vulnerable to| E & F & G
    B -.->|Mitigates| F
    B -.->|Vulnerable to| E & G
    C -.->|Mitigates| E & G
    D -.->|Mitigates| E & F & G
```
