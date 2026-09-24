<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CheckExistingSupplier" select="()"/>
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:param name="DefaultProcurementBU" select="'US1 Business Unit'"/>
   <xsl:param name="FaultMessage" select="'Unexpected error while creating the supplier in Oracle ERP Cloud.'"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <!-- Template params: SupplierId = $CreateSupplier/SupplierId, childResource = 'addresses' -->
      <erp:SupplierChild>
         <erp:AddressName><xsl:value-of select="$req/src:address/src:addressName"/></erp:AddressName>
         <erp:AddressLine1><xsl:value-of select="$req/src:address/src:addressLine1"/></erp:AddressLine1>
         <xsl:if test="$req/src:address/src:addressLine2"><erp:AddressLine2><xsl:value-of select="$req/src:address/src:addressLine2"/></erp:AddressLine2></xsl:if>
         <erp:City><xsl:value-of select="$req/src:address/src:city"/></erp:City>
         <erp:State><xsl:value-of select="$req/src:address/src:state"/></erp:State>
         <erp:PostalCode><xsl:value-of select="$req/src:address/src:postalCode"/></erp:PostalCode>
         <erp:CountryCode><xsl:value-of select="upper-case($req/src:address/src:country)"/></erp:CountryCode>
         <erp:AddressPurposeOrderingFlag>true</erp:AddressPurposeOrderingFlag>
         <erp:AddressPurposeRemitToFlag>true</erp:AddressPurposeRemitToFlag>
      </erp:SupplierChild>
   </xsl:template>
</xsl:stylesheet>
