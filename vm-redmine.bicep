@description('Nombre de usuario administrador')
param adminUsername string = 'azureuser'

@secure()
@description('Contraseña del administrador')
param adminPassword string  = 'ContrasenaSegura123!'

@description('Ubicación de los recursos')
param location string = 'westus3'

@description('Nombre del grupo de recursos')
param resourceGroupName string = 'rg-redmine'

// Crear un nuevo grupo de recursos
resource newRG 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}
// Red Virtual
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'redmine-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

// IP Pública
resource publicIp 'Microsoft.Network/publicIPAddresses@2022-05-01' = {
  name: 'redmine-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}



// NIC
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'redmine-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}
// Máquina Virtual (corregido)
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'redmine-vm'
  location: location
  properties: {
    hardwareProfile: {
      // <- Quitar cualquier espacio/tab antes del nombre
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: 'redmine'
      adminUsername: adminUsername
      adminPassword: adminPassword
      // --- Opcional: customData (base64) si tu script es corto y no contiene secretos
      customData: base64(loadTextContent('install-redmine.sh'))
      // --- Recomendado: linuxConfiguration explícito
      linuxConfiguration: {
        disablePasswordAuthentication: false // o true si vas a usar SSH keys
        // ssh: {
        //   publicKeys: [
        //     {
        //       path: '/home/azureuser/.ssh/authorized_keys'
        //       keyData: 'ssh-rsa AAAA...'
        //     }
        //   ]
        // }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}


output publicIpAddress string = publicIp.properties.ipAddress
