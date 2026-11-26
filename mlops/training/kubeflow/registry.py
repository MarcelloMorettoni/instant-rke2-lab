"""Lists every model, version and artifact in Kubeflow Model Registry (REST API)."""
import requests

API = "http://model-registry-service.kubeflow.svc.cluster.local:8080/api/model_registry/v1alpha3"
for model in requests.get(f"{API}/registered_models", timeout=30).json()["items"]:
    print("MODEL", model["name"])
    for version in requests.get(f"{API}/registered_models/{model['id']}/versions", timeout=30).json()["items"]:
        props = {k: v.get("string_value", v.get("double_value")) for k, v in version["customProperties"].items()}
        print("  VERSION", version["name"], props)
        for artifact in requests.get(f"{API}/model_versions/{version['id']}/artifacts", timeout=30).json()["items"]:
            print("    ARTIFACT", artifact["uri"])
