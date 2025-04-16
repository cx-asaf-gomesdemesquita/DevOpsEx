#!/bin/bash

# Create a deployment script for the DevOps challenge
# Usage: ./deploy.sh install | uninstall

set -e

function install_solution() {
    echo "Installing the DevOps Challenge solution..."
    
    # Create K3d cluster
    echo "Creating K3d cluster..."
    k3d cluster create mycluster \
      --servers 1 \
      --agents 2 \
      --port "80:80@loadbalancer" \
      --api-port 6443
    
    # Add Helm repositories
    echo "Adding Helm repositories..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add jenkins https://charts.jenkins.io
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    
    # Deploy PostgreSQL
    echo "Deploying PostgreSQL..."
    kubectl create namespace database
    kubectl create secret generic postgres-credentials \
      --namespace database \
      --from-literal=postgres-password=admin123 \
      --from-literal=postgres-username=admin
    
    helm install postgres bitnami/postgresql \
      --namespace database \
      --set auth.username=admin \
      --set auth.password=admin123 \
      --set auth.database=postgres \
      --set persistence.enabled=true \
      --set persistence.size=8Gi
    
    # Deploy Jenkins
    echo "Deploying Jenkins..."
    kubectl create namespace jenkins
    
    cat > jenkins-values.yaml << EOF
controller:
  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - git:latest
    - configuration-as-code:latest
    - job-dsl:latest
  admin:
    username: admin
    password: admin123
  serviceType: ClusterIP
  
  # For HA configuration
  replicas: 2
  
persistence:
  enabled: true
  size: 10Gi

serviceAccount:
  create: true
  
# Allow Jenkins to create pods in the cluster
rbac:
  create: true
EOF
    
    helm install jenkins jenkins/jenkins --namespace jenkins -f jenkins-values.yaml
    
    # Setup Jenkins worker namespace
    echo "Setting up Jenkins worker namespace..."
    kubectl create namespace jenkins-workers
    
    cat > jenkins-worker-role.yaml << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-worker
  namespace: jenkins-workers
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec", "pods/log", "persistentvolumeclaims", "events"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-worker-binding
  namespace: jenkins-workers
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins
roleRef:
  kind: Role
  name: jenkins-worker
  apiGroup: rbac.authorization.k8s.io
EOF
    
    kubectl apply -f jenkins-worker-role.yaml
    
    # Copy the postgres credentials secret to the jenkins-workers namespace
    kubectl get secret postgres-credentials -n database -o yaml | \
      sed 's/namespace: database/namespace: jenkins-workers/' | \
      kubectl apply -f -
    
    # Deploy Traefik
    echo "Deploying Traefik..."
    kubectl create namespace traefik
    
    # Check for existing IngressClass
    if kubectl get ingressclass traefik &> /dev/null; then
        echo "Deleting existing Traefik IngressClass..."
        kubectl delete ingressclass traefik
    fi
    
    cat > traefik-values.yaml << EOF
deployment:
  replicas: 2

ingressRoute:
  dashboard:
    enabled: true

additionalArguments:
  - "--api.dashboard=true"
  - "--entrypoints.web.address=:80"
  - "--providers.kubernetesingress"

service:
  type: LoadBalancer
EOF
    
    helm install traefik traefik/traefik --namespace traefik -f traefik-values.yaml
    
    # Create Ingress resources
    echo "Creating Ingress resources..."
    
    cat > jenkins-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins-ingress
  namespace: jenkins
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - host: jenkins.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jenkins
            port:
              number: 8080
EOF
    
    kubectl apply -f jenkins-ingress.yaml
    
    cat > traefik-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: traefik-dashboard-ingress
  namespace: traefik
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - host: traefik.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: traefik
            port:
              number: 9000
EOF
    
    kubectl apply -f traefik-ingress.yaml
    
    # Deploy Grafana
    echo "Deploying Grafana..."
    kubectl create namespace monitoring
    
    cat > grafana-values.yaml << EOF
adminUser: admin
adminPassword: admin123

persistence:
  enabled: true
  size: 5Gi

service:
  type: ClusterIP

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: PostgreSQL
      type: postgres
      url: postgres-postgresql.database.svc.cluster.local:5432
      user: admin
      secureJsonData:
        password: admin123
      database: postgres
      jsonData:
        sslmode: "disable"
      isDefault: true
EOF
    
    helm install grafana grafana/grafana --namespace monitoring -f grafana-values.yaml
    
    cat > grafana-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - host: grafana.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
EOF
    
    kubectl apply -f grafana-ingress.yaml
    
    # Update /etc/hosts file
    echo "Updating /etc/hosts file..."
    grep -qxF "127.0.0.1 jenkins.local grafana.local traefik.local" /etc/hosts || \
      echo "127.0.0.1 jenkins.local grafana.local traefik.local" | sudo tee -a /etc/hosts
    
    # Configure Jenkins Job DSL
    echo "Creating Jenkins Job DSL..."
    cat > jenkins-job-dsl.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: jenkins-job-dsl
  namespace: jenkins
data:
  job-dsl.groovy: |
    folder('KubernetesJobs') {
        description('Jobs that run on Kubernetes')
    }
    
    pipelineJob('KubernetesJobs/db-timestamp-job') {
        definition {
            cps {
                script('''
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
metadata:
  namespace: jenkins-workers
spec:
  containers:
  - name: postgres-client
    image: postgres:latest
    command:
    - cat
    tty: true
    env:
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: postgres-credentials
          key: postgres-password
"""
            namespace 'jenkins-workers'
            defaultContainer 'postgres-client'
        }
    }
    triggers {
        cron('*/5 * * * *')
    }
    stages {
        stage('Record Time') {
            steps {
                container('postgres-client') {
                    sh "psql -h postgres-postgresql.database.svc.cluster.local -U admin -d postgres -c \\"CREATE TABLE IF NOT EXISTS time_records (id SERIAL PRIMARY KEY, recorded_time TIMESTAMP);\\""
                    sh "psql -h postgres-postgresql.database.svc.cluster.local -U admin -d postgres -c \\"INSERT INTO time_records (recorded_time) VALUES (NOW());\\""
                    sh "echo 'Time recorded successfully!'"
                }
            }
        }
    }
}
                ''')
                sandbox(true)
            }
        }
    }
EOF
    
    kubectl apply -f jenkins-job-dsl.yaml
    
    # Setup Terraform for Grafana
    echo "Setting up Terraform for Grafana..."
    mkdir -p grafana-terraform
    cd grafana-terraform
    
    cat > main.tf << EOF
terraform {
  required_providers {
    grafana = {
      source = "grafana/grafana"
      version = "~> 2.0"
    }
  }
}

provider "grafana" {
  url  = "http://grafana.local"
  auth = "admin:admin123"
}

# Create a PostgreSQL dashboard
resource "grafana_dashboard" "postgres_metrics" {
  config_json = file("dashboard.json")
}
EOF
    
    cat > dashboard.json << 'EOF'
{
  "annotations": {
    "list": []
  },
  "editable": true,
  "graphTooltip": 0,
  "panels": [
    {
      "datasource": "PostgreSQL",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "drawStyle": "line",
            "fillOpacity": 20
          },
          "unit": "short"
        }
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "title": "Active Queries",
      "type": "timeseries",
      "targets": [
        {
          "datasource": "PostgreSQL",
          "format": "time_series",
          "group": [],
          "metricColumn": "none",
          "rawQuery": true,
          "rawSql": "SELECT extract(epoch from now()) AS time, COUNT(*) as value FROM pg_stat_activity WHERE state = 'active';",
          "refId": "A",
          "select": [[{"params": ["value"],"type": "column"}]],
          "timeColumn": "time"
        }
      ]
    },
    {
      "datasource": "PostgreSQL",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "drawStyle": "line",
            "fillOpacity": 20
          },
          "unit": "bytes"
        }
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "title": "Database Size",
      "type": "timeseries",
      "targets": [
        {
          "datasource": "PostgreSQL",
          "format": "time_series",
          "group": [],
          "metricColumn": "none",
          "rawQuery": true,
          "rawSql": "SELECT extract(epoch from now()) AS time, pg_database_size(current_database()) as value;",
          "refId": "A",
          "select": [[{"params": ["value"],"type": "column"}]],
          "timeColumn": "time"
        }
      ]
    },
    {
      "datasource": "PostgreSQL",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "drawStyle": "line",
            "fillOpacity": 20
          }
        }
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "title": "Total Connections",
      "type": "timeseries",
      "targets": [
        {
          "datasource": "PostgreSQL",
          "format": "time_series",
          "group": [],
          "metricColumn": "none",
          "rawQuery": true,
          "rawSql": "SELECT extract(epoch from now()) AS time, (SELECT COUNT(*) FROM pg_stat_activity) as value;",
          "refId": "A",
          "select": [[{"params": ["value"],"type": "column"}]],
          "timeColumn": "time"
        }
      ]
    },
    {
      "datasource": "PostgreSQL",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "drawStyle": "line",
            "fillOpacity": 20
          }
        }
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 8
      },
      "title": "Timestamp Records Count",
      "type": "timeseries",
      "targets": [
        {
          "datasource": "PostgreSQL",
          "format": "time_series",
          "group": [],
          "metricColumn": "none",
          "rawQuery": true,
          "rawSql": "SELECT extract(epoch from now()) AS time, COUNT(*) as value FROM time_records;",
          "refId": "A",
          "select": [[{"params": ["value"],"type": "column"}]],
          "timeColumn": "time"
        }
      ]
    }
  ],
  "refresh": "5s",
  "schemaVersion": 30,
  "style": "dark",
  "title": "PostgreSQL Performance Metrics",
  "version": 0
}
EOF
    
    # Wait for Grafana to be ready
    echo "Waiting for Grafana to be ready..."
    kubectl rollout status deployment/grafana -n monitoring --timeout=300s
    
    # Apply Terraform
    echo "Applying Terraform configuration..."
    terraform init
    terraform apply -auto-approve
    
    cd ..
    
    echo "Installation completed successfully!"
    echo ""
    echo "Access your services at:"
    echo "- Jenkins: http://jenkins.local"
    echo "- Grafana: http://grafana.local"
    echo "- Traefik Dashboard: http://traefik.local"
    echo ""
    echo "Credentials for all services:"
    echo "- Username: admin"
    echo "- Password: admin123"
    echo ""
    echo "Setup Jenkins job manually if not created automatically:"
    echo "1. Go to Jenkins http://jenkins.local"
    echo "2. Create a new job named 'seed-job' of type 'Freestyle project'"
    echo "3. Add a build step 'Process Job DSLs'"
    echo "4. Copy the Job DSL script from the jenkins-job-dsl.yaml file"
    echo "5. Save and run the job"
}

function uninstall_solution() {
    echo "Uninstalling the DevOps Challenge solution..."
    
    # Delete Terraform resources
    if [ -d "grafana-terraform" ]; then
        cd grafana-terraform
        terraform destroy -auto-approve || true
        cd ..
    fi
    
    # Delete Helm releases
    echo "Deleting Helm releases..."
    helm uninstall grafana -n monitoring || true
    helm uninstall traefik -n traefik || true
    helm uninstall jenkins -n jenkins || true
    helm uninstall postgres -n database || true
    
    # Delete namespaces
    echo "Deleting namespaces..."
    kubectl delete namespace monitoring || true
    kubectl delete namespace traefik || true
    kubectl delete namespace jenkins || true
    kubectl delete namespace jenkins-workers || true
    kubectl delete namespace database || true
    
    # Delete K3d cluster
    echo "Deleting K3d cluster..."
    k3d cluster delete mycluster || true
    
    echo "Uninstallation completed successfully!"
}

# Main script
if [ "$1" == "install" ]; then
    install_solution
elif [ "$1" == "uninstall" ]; then
    uninstall_solution
else
    echo "Usage: $0 install|uninstall"
    exit 1
fi
