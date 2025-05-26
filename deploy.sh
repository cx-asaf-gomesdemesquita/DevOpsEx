#!/bin/bash

# Create a deployment script for the DevOps challenge
# Usage: ./deploy.sh install | uninstall

set -e

add_helm_repo_if_missing() {
  local repo_name="$1"
  local repo_url="$2"

  if ! helm repo list | awk '{print $1}' | grep -q "^${repo_name}$"; then
    echo "Adding Helm repo: $repo_name"
    helm repo add "$repo_name" "$repo_url"
  else
    echo "Helm repo '$repo_name' already exists. Skipping..."
  fi
}

# Create Jenkins configuration scripts
function create_jenkins_scripts() {
    echo "Creating Jenkins initialization scripts..."
    
    # Create directory for Jenkins scripts
    mkdir -p jenkins-scripts
    
    # Create Jenkins initialization script
    cat > jenkins-scripts/init.groovy << 'EOF'
import jenkins.model.*
import hudson.model.*
import javaposse.jobdsl.plugin.*
import org.csanchez.jenkins.plugins.kubernetes.*
import java.nio.file.*
println "Starting initialization script..."
Thread.start {
    println "Waiting for Jenkins to initialize..."
    sleep(30000)  // Increased sleep time to allow Jenkins to fully start
    def jenkins = Jenkins.getInstanceOrNull()
    if (jenkins == null) {
        println("Jenkins instance is not ready. Exiting script.")
        return
    }
    // Step 1: Ensure Kubernetes Cloud is Configured
    def k8sCloudName = "kubernetes"
    def existingCloud = jenkins.clouds.getByName(k8sCloudName)
    if (existingCloud == null) {
        println("No Kubernetes cloud found. Creating new one...")
        def k8sCloud = new KubernetesCloud(k8sCloudName)
        k8sCloud.setServerUrl("https://kubernetes.default.svc.cluster.local")
        k8sCloud.setNamespace("jenkins-workers")
        k8sCloud.setJenkinsUrl("http://jenkins.jenkins.svc.cluster.local:8080")
        k8sCloud.setJenkinsTunnel("jenkins-agent.jenkins.svc.cluster.local:50000")
        k8sCloud.setRetentionTimeout(5)
        k8sCloud.setContainerCap(10)
        jenkins.clouds.add(k8sCloud)
        jenkins.save()
        println "✅ Kubernetes cloud configured successfully."
    } else {
        println "✅ Kubernetes cloud is already configured."
    }
    // Step 2: Create JobDSL Seed Job
    def seedJobName = "JobDSL-Seed"
    def existingJob = jenkins.getItem(seedJobName)
    if (existingJob != null) {
        println("✅ JobDSL Seed Job already exists: ${seedJobName}")
    } else {
        println("🚀 Creating JobDSL Seed Job: ${seedJobName}")
        def job = jenkins.createProject(FreeStyleProject, seedJobName)
        job.setDisplayName("Seed Job for Kubernetes Worker Pods")
        def dslScriptPath = "/var/jenkins_home/job-dsl.groovy"
        def dslScript = new File(dslScriptPath).text
        def dslBuilder = new ExecuteDslScripts()
        dslBuilder.setScriptText(dslScript)
        dslBuilder.setSandbox(true)
        job.buildersList.add(dslBuilder)
        job.save()
        println("🔄 Triggering seed job build...")
        job.scheduleBuild2(0)
        println("✅ JobDSL Seed Job Created and Triggered: ${seedJobName}")
    }
}
EOF

    # Create the Job DSL script
    cat > jenkins-scripts/job-dsl.groovy << 'EOF'
// Example Job DSL script that creates a simple pipeline job
pipelineJob('example-pipeline') {
    definition {
        cps {
            script('''
                pipeline {
                    agent {
                        kubernetes {
                            yaml """
                            apiVersion: v1
                            kind: Pod
                            spec:
                              containers:
                              - name: maven
                                image: maven:3.8.4-openjdk-11
                                command:
                                - cat
                                tty: true
                              - name: docker
                                image: docker:latest
                                command:
                                - cat
                                tty: true
                                volumeMounts:
                                - name: docker-sock
                                  mountPath: /var/run/docker.sock
                              volumes:
                              - name: docker-sock
                                hostPath:
                                  path: /var/run/docker.sock
                            """
                        }
                    }
                    stages {
                        stage('Echo') {
                            steps {
                                echo 'Hello from Kubernetes pod!'
                            }
                        }
                    }
                }
            ''')
            sandbox()
        }
    }
}

// Create a job that connects to PostgreSQL database
job('db-connection-test') {
    description('Tests connection to PostgreSQL database')
    steps {
        shell('''
            #!/bin/bash
            echo "Testing connection to PostgreSQL..."
            PGPASSWORD=admin123 pg_isready -h postgres-postgresql.database.svc.cluster.local -p 5432 -U admin
            if [ $? -eq 0 ]; then
                echo "Connection successful!"
            else
                echo "Connection failed!"
                exit 1
            fi
        ''')
    }
    triggers {
        cron('H/30 * * * *')  // Run every 30 minutes
    }
}
EOF
}

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
    add_helm_repo_if_missing traefik https://helm.traefik.io/traefik
    add_helm_repo_if_missing jenkins https://charts.jenkins.io
    add_helm_repo_if_missing bitnami https://charts.bitnami.com/bitnami
    add_helm_repo_if_missing grafana https://grafana.github.io/helm-charts
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
    
    # Create Jenkins scripts before deploying Jenkins
    create_jenkins_scripts
    
    # Deploy Jenkins
    echo "Deploying Jenkins..."
    kubectl create namespace jenkins
    
    # Create a ConfigMap to store our Jenkins scripts
    echo "Creating Jenkins scripts ConfigMap..."
    kubectl create configmap jenkins-scripts \
      --namespace jenkins \
      --from-file=init.groovy=jenkins-scripts/init.groovy \
      --from-file=job-dsl.groovy=jenkins-scripts/job-dsl.groovy
    
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
  
  # Mount our initialization scripts
  initScripts:
    - |
      #!/bin/bash
      # Copy scripts to the init.groovy.d directory for Jenkins to run them at startup
      mkdir -p /var/jenkins_home/init.groovy.d
      cp /var/jenkins_scripts/init.groovy /var/jenkins_home/init.groovy.d/
      cp /var/jenkins_scripts/job-dsl.groovy /var/jenkins_home/job-dsl.groovy
  
  # Adding volume mounts for our scripts
  additionalVolumes:
    - name: jenkins-scripts
      configMap:
        name: jenkins-scripts
  additionalVolumeMounts:
    - name: jenkins-scripts
      mountPath: /var/jenkins_scripts
  
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
  - "--providers.kubernetescrd"
  - "--log.level=INFO"

service:
  type: LoadBalancer

# Explicitly enable the ingress controller
ingressClass:
  enabled: true
  isDefaultClass: true
EOF
    
    helm install traefik traefik/traefik --namespace traefik -f traefik-values.yaml

echo "Creating Traefik IngressClass explicitly..."
cat > traefik-ingressclass.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: traefik.io/ingress-controller
EOF

kubectl apply -f traefik-ingressclass.yaml
    
    # Create Ingress resources
    echo "Creating Ingress resources..."
    
    cat > jenkins-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins-ingress
  namespace: jenkins
spec:
  ingressClassName: traefik
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
spec:
  ingressClassName: traefik
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
spec:
  ingressClassName: traefik
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
    
    # Create time_records table for dashboard data
    echo "Creating time_records table in PostgreSQL..."
    kubectl exec -n database -it svc/postgres-postgresql -- bash -c "PGPASSWORD=admin123 psql -U admin -d postgres -c 'CREATE TABLE IF NOT EXISTS time_records (id SERIAL PRIMARY KEY, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP);'"
    
    # Wait for Jenkins to be ready
    echo "Waiting for Jenkins to be ready..."
    kubectl rollout status statefulset/jenkins -n jenkins --timeout=300s
    
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
    echo "Jenkins will automatically create the following jobs:"
    echo "1. JobDSL-Seed - A seed job that uses Job DSL to create other jobs"
    echo "2. example-pipeline - A Kubernetes pipeline example"
    echo "3. db-connection-test - A job that tests PostgreSQL connectivity"
    echo ""
    echo "Note: The jobs will be created automatically during Jenkins startup."
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
    
    # Cleanup Jenkins scripts directory
    if [ -d "jenkins-scripts" ]; then
        rm -rf jenkins-scripts
    fi
    
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
