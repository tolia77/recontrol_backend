require "rails_helper"

RSpec.describe DeviceSharesController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/device_shares").to route_to("device_shares#index")
    end

    it "routes to #show" do
      expect(get: "/device_shares/1").to route_to("device_shares#show", id: "1")
    end


    it "routes to #create" do
      expect(post: "/device_shares").to route_to("device_shares#create")
    end

    it "routes to #update via PUT" do
      expect(put: "/device_shares/1").to route_to("device_shares#update", id: "1")
    end

    it "routes to #update via PATCH" do
      expect(patch: "/device_shares/1").to route_to("device_shares#update", id: "1")
    end

    it "routes to #destroy" do
      expect(delete: "/device_shares/1").to route_to("device_shares#destroy", id: "1")
    end
  end
end
