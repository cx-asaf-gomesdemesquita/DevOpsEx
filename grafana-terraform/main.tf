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
